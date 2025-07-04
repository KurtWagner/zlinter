//! Linting stuff

/// A loaded and parsed zig file that is given to zig lint rules.
pub const LintDocument = struct {
    path: []const u8,
    handle: *zls.DocumentStore.Handle,
    analyser: *zls.Analyser,

    pub fn deinit(self: *LintDocument, gpa: std.mem.Allocator) void {
        self.analyser.deinit();
        gpa.destroy(self.analyser);
        gpa.free(self.path);
    }

    // TODO: Add tests for this:
    pub inline fn resolveTypeOfNode(self: @This(), node: std.zig.Ast.Node.Index) !?zls.Analyser.Type {
        return switch (version.zig) {
            .@"0.15" => self.analyser.resolveTypeOfNode(.of(node, self.handle)),
            .@"0.14" => self.analyser.resolveTypeOfNode(.{ .handle = self.handle, .node = node }),
        };
    }

    // TODO: Add tests for this:
    pub inline fn resolveTypeOfTypeNode(self: @This(), node: std.zig.Ast.Node.Index) !?zls.Analyser.Type {
        const resolved_type = try self.resolveTypeOfNode(node) orelse return null;
        const instance_type = if (resolved_type.isMetaType()) resolved_type else switch (version.zig) {
            .@"0.14" => resolved_type.instanceTypeVal(self.analyser) orelse resolved_type,
            .@"0.15" => try resolved_type.instanceTypeVal(self.analyser) orelse resolved_type,
        };

        return instance_type.resolveDeclLiteralResultType();
    }

    // TODO: Write tests and clean this up as they're not really all needed
    pub const TypeKind = enum {
        /// Fallback when it's not a type or any of the identifiable `*_instance`
        /// kinds - usually this means its a primitive. e.g., `var age: u32 = 24;`
        other,
        /// e.g., has type `fn () void`
        @"fn",
        /// e.g., has type `fn () type`
        fn_returns_type,
        opaque_instance,
        /// e.g., has type `enum { ... }`
        enum_instance,
        /// e.g., has type `struct { field: u32 }`
        struct_instance,
        /// e.g., has type `union { a: u32, b: u32 }`
        union_instance,
        /// e.g., `const MyError = error { NotFound, Invalid };`
        error_type,
        /// e.g., `const Callback = *const fn () void;`
        fn_type,
        /// e.g., `const Callback = *const fn () void;`
        fn_type_returns_type,
        /// Is type `type` and not categorized as any other `*_type`
        type,
        /// e.g., `const Result = enum { good, bad };`
        enum_type,
        /// e.g., `const Person = struct { name: [] const u8 };`
        struct_type,
        /// e.g., `const colors = struct { const color = "red"; };`
        namespace_type,
        /// e.g., `const Color = union { rgba: Rgba, rgb: Rgb };`
        union_type,
        opaque_type,
    };

    /// Resolves a given declaration or container field by looking at the type
    /// node (if any) and then the value node (if any) to resolve the type.
    ///
    /// This will return null if the kind could not be resolved, usually indicating
    /// that the input was unexpected / invalid.
    pub fn resolveTypeKind(self: @This(), input: union(enum) {
        var_decl: std.zig.Ast.full.VarDecl,
        container_field: std.zig.Ast.full.ContainerField,
    }) !?TypeKind {
        const maybe_type_node, const maybe_value_node = inputs: {
            const t, const v = switch (input) {
                .var_decl => |var_decl| .{
                    var_decl.ast.type_node,
                    var_decl.ast.init_node,
                },
                .container_field => |container_field| .{
                    container_field.ast.type_expr,
                    container_field.ast.value_expr,
                },
            };
            break :inputs .{
                shims.NodeIndexShim.initOptional(t),
                shims.NodeIndexShim.initOptional(v),
            };
        };

        var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
        var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;

        const tree = self.handle.tree;

        // First we try looking for a type node in the declaration
        if (maybe_type_node) |type_node| {
            // std.debug.print("TypeNode - Before: {s}\n", .{tree.getNodeSource(type_node.toNodeIndex())});
            // std.debug.print("TypeNode - Tag Before: {}\n", .{shims.nodeTag(tree, type_node.toNodeIndex())});

            const node = shims.unwrapNode(tree, type_node.toNodeIndex(), .{});
            // std.debug.print("TypeNode - After: {s}\n", .{tree.getNodeSource(node)});
            // std.debug.print("TypeNode - Tag After: {}\n", .{shims.nodeTag(tree, node)});

            if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
                if (shims.NodeIndexShim.initOptional(fn_proto.ast.return_type)) |return_node_shim| {
                    const return_node = shims.unwrapNode(tree, return_node_shim.toNodeIndex(), .{});

                    // std.debug.print("TypeNode - Return unwrapped: {s}\n", .{tree.getNodeSource(return_node)});
                    // std.debug.print("TypeNode - Return unwrapped tag: {}\n", .{shims.nodeTag(tree, return_node)});

                    // If it's a function proto, then return whether or not the function returns a type
                    return if (shims.isIdentiferKind(tree, shims.unwrapNode(tree, return_node, .{}), .type))
                        .fn_returns_type
                    else
                        .@"fn";
                } else {
                    return .@"fn";
                }
            } else if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {

                // If's it's a container declaration (e.g., struct {}) then resolve what type of container
                switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
                    // Instance of namespace should be impossible but to be safe
                    // we will just return null to say we couldn't resolve the kind
                    .keyword_struct => return if (shims.isContainerNamespace(tree, container_decl)) null else .struct_instance,
                    .keyword_union => return .union_instance,
                    .keyword_opaque => return .opaque_instance,
                    .keyword_enum => return .enum_instance,
                    inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
                }
            } else if (shims.isIdentiferKind(tree, node, .type)) {
                return .type;
            } else if (try self.resolveTypeOfNode(node)) |type_node_type| {
                const decl = type_node_type.resolveDeclLiteralResultType();
                if (decl.isUnionType()) {
                    return .union_instance;
                } else if (decl.isEnumType()) {
                    return .enum_instance;
                } else if (decl.isStructType()) {
                    return .struct_instance;
                } else if (decl.isTypeFunc()) {
                    return .fn_returns_type;
                } else if (decl.isFunc()) {
                    return .@"fn";
                }
            }
            return .other;
        }

        // Then we look at the initialisation value if a type couldn't be used
        if (maybe_value_node) |value_node| {
            // std.debug.print("InitNode - Before: {s}\n", .{tree.getNodeSource(value_node.toNodeIndex())});
            // std.debug.print("InitNode - Tag Before: {}\n", .{shims.nodeTag(tree, value_node.toNodeIndex())});

            const node = shims.unwrapNode(tree, value_node.toNodeIndex(), .{});
            // std.debug.print("InitNode - After: {s}\n", .{tree.getNodeSource(node)});
            // std.debug.print("InitNode - Tag After: {}\n", .{shims.nodeTag(tree, node)});

            // LIMITATION: All builtin calls to type of and type will return
            // `type` without any resolution.
            switch (shims.nodeTag(tree, node)) {
                .builtin_call_two,
                .builtin_call_two_comma,
                .builtin_call,
                .builtin_call_comma,
                => {
                    inline for (&.{ "@Type", "@TypeOf" }) |builtin_name| {
                        if (std.mem.eql(u8, builtin_name, tree.tokenSlice(shims.nodeMainToken(tree, node)))) {
                            return .type;
                        }
                    }
                },
                .error_set_decl => return .error_type,
                else => {},
            }

            if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
                switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
                    .keyword_struct => return if (shims.isContainerNamespace(tree, container_decl)) .namespace_type else .struct_type,
                    .keyword_union => return .union_type,
                    .keyword_opaque => return .opaque_type,
                    .keyword_enum => return .enum_type,
                    inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
                }
            } else if (try self.resolveTypeOfNode(node)) |init_node_type| {
                // std.debug.print("InitNode - ResolvedNode type: {}\n", .{init_node_type});
                // try self.dumpType(init_node_type, 0);

                const decl = init_node_type.resolveDeclLiteralResultType();

                // std.debug.print("InitNode - Resolved type: {}\n", .{decl});
                // try self.dumpType(decl, 0);

                const is_error_container =
                    if (std.meta.hasMethod(@TypeOf(decl), "isErrorSetType"))
                        decl.isErrorSetType(self.analyser)
                    else switch (decl.data) {
                        .container => |container| result: {
                            const container_node, const container_tree = switch (version.zig) {
                                .@"0.14" => .{ container.toNode(), container.handle.tree },
                                .@"0.15" => .{ container.scope_handle.toNode(), container.scope_handle.handle.tree },
                            };

                            if (shims.NodeIndexShim.init(container_node).index != 0) {
                                switch (shims.nodeTag(container_tree, container_node)) {
                                    .error_set_decl => break :result true,
                                    else => {},
                                }
                            }
                            break :result false;
                        },
                        else => false,
                    };

                if (is_error_container) {
                    return .error_type;
                } else if (decl.isNamespace()) {
                    return if (init_node_type.is_type_val) .namespace_type else null;
                } else if (decl.isUnionType()) {
                    return if (init_node_type.is_type_val) .union_type else .union_instance;
                } else if (decl.isEnumType()) {
                    return if (init_node_type.is_type_val) .enum_type else .enum_instance;
                } else if (decl.isOpaqueType()) {
                    return if (init_node_type.is_type_val) .opaque_type else null;
                } else if (decl.isStructType()) {
                    return if (init_node_type.is_type_val) .struct_type else .struct_instance;
                } else if (decl.isTypeFunc()) {
                    return if (init_node_type.is_type_val) .fn_type_returns_type else .fn_returns_type;
                } else if (decl.isFunc()) {
                    return if (init_node_type.is_type_val) .fn_type else .@"fn";
                } else {
                    if (init_node_type.is_type_val) {
                        switch (init_node_type.data) {
                            .ip_index => return .type,
                            else => {},
                        }
                    }
                    return .other;
                }
            }
        }
        return null;
    }

    /// For debugging purposes only, should never be left in
    pub fn dumpType(self: @This(), t: zls.Analyser.Type, indent_size: u32) !void {
        var buffer: [128]u8 = @splat(' ');
        const indent = buffer[0..indent_size];

        std.debug.print("{s}------------------------------------\n", .{indent});
        std.debug.print("{s}is_type_val: {}\n", .{ indent, t.is_type_val });
        std.debug.print("{s}isContainerType: {}\n", .{ indent, t.isContainerType() });
        std.debug.print("{s}isEnumLiteral: {}\n", .{ indent, t.isEnumLiteral() });
        std.debug.print("{s}isEnumType: {}\n", .{ indent, t.isEnumType() });
        std.debug.print("{s}isFunc: {}\n", .{ indent, t.isFunc() });
        std.debug.print("{s}isGenericFunc: {}\n", .{ indent, t.isGenericFunc() });
        std.debug.print("{s}isMetaType: {}\n", .{ indent, t.isMetaType() });
        std.debug.print("{s}isNamespace: {}\n", .{ indent, t.isNamespace() });
        std.debug.print("{s}isOpaqueType: {}\n", .{ indent, t.isOpaqueType() });
        std.debug.print("{s}isStructType: {}\n", .{ indent, t.isStructType() });
        std.debug.print("{s}isTaggedUnion: {}\n", .{ indent, t.isTaggedUnion() });
        std.debug.print("{s}isTypeFunc: {}\n", .{ indent, t.isTypeFunc() });
        std.debug.print("{s}isUnionType: {}\n", .{ indent, t.isUnionType() });

        if (t.data == .ip_index) {
            std.debug.print("{s}Primitive: {}\n", .{ indent, t.data.ip_index.type });
            if (t.data.ip_index.index) |tt| {
                std.debug.print("{s}Value: {}\n", .{ indent, tt });
            }
        }

        const decl_literal = t.resolveDeclLiteralResultType();
        if (!decl_literal.eql(t)) {
            std.debug.print("{s}Decl literal result type:\n", .{indent});
            try self.dumpType(decl_literal, indent_size + 4);
        }

        if (t.instanceTypeVal(self.analyser)) |instance| {
            if (!instance.eql(t)) {
                std.debug.print("{s}Instance result type:\n", .{indent});
                try self.dumpType(instance, indent_size + 4);
            }
        }
    }
};

/// The context of all document and rule executions.
pub const LintContext = struct {
    thread_pool: if (builtin.single_threaded) void else std.Thread.Pool,
    diagnostics_collection: zls.DiagnosticsCollection,
    intern_pool: zls.analyser.InternPool,
    document_store: zls.DocumentStore,
    gpa: std.mem.Allocator,

    pub fn init(self: *LintContext, config: zls.Config, gpa: std.mem.Allocator) !void {
        self.* = .{
            .gpa = gpa,
            .diagnostics_collection = .{ .allocator = gpa },
            .intern_pool = try .init(gpa),
            .thread_pool = undefined, // set below.
            .document_store = undefined, // set below.
        };

        if (!builtin.single_threaded) {
            self.thread_pool.init(.{
                .allocator = gpa,
                .n_jobs = @min(4, std.Thread.getCpuCount() catch 1),
            }) catch @panic("Failed to init thread pool");
        }
        self.document_store = zls.DocumentStore{
            .allocator = gpa,
            .diagnostics_collection = &self.diagnostics_collection,
            .config = switch (version.zig) {
                .@"0.15" => .{
                    .zig_exe_path = config.zig_exe_path,
                    .zig_lib_dir = dir: {
                        if (config.zig_lib_path) |zig_lib_path| {
                            if (std.fs.openDirAbsolute(zig_lib_path, .{})) |zig_lib_dir| {
                                break :dir .{
                                    .handle = zig_lib_dir,
                                    .path = zig_lib_path,
                                };
                            } else |err| {
                                std.log.err("failed to open zig library directory '{s}': {s}", .{ zig_lib_path, @errorName(err) });
                            }
                        }
                        break :dir null;
                    },
                    .build_runner_path = config.build_runner_path,
                    .builtin_path = config.builtin_path,
                    .global_cache_dir = dir: {
                        if (config.global_cache_path) |global_cache_path| {
                            if (std.fs.openDirAbsolute(global_cache_path, .{})) |global_cache_dir| {
                                break :dir .{
                                    .handle = global_cache_dir,
                                    .path = global_cache_path,
                                };
                            } else |err| {
                                std.log.err("failed to open zig library directory '{s}': {s}", .{ global_cache_path, @errorName(err) });
                            }
                        }
                        break :dir null;
                    },
                },
                .@"0.14" => .fromMainConfig(config),
            },

            .thread_pool = &self.thread_pool,
        };
    }

    pub fn deinit(self: *LintContext) void {
        self.diagnostics_collection.deinit();
        self.intern_pool.deinit(self.gpa);
        self.document_store.deinit();
        if (!builtin.single_threaded) self.thread_pool.deinit();
    }

    /// Loads and parses zig file into the document store.
    ///
    /// Caller is responsible for calling deinit once done.
    pub fn loadDocument(self: *LintContext, path: []const u8, gpa: std.mem.Allocator, arena: std.mem.Allocator) !?LintDocument {
        var mem: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&mem);
        const uri = try zls.URI.fromPath(
            fba.allocator(),
            std.fs.cwd().realpathAlloc(
                fba.allocator(),
                path,
            ) catch {
                std.log.err("Failed to create real path for: {s}", .{path});
                return null;
            },
        );

        const handle = self.document_store.getOrLoadHandle(uri) orelse return null;
        const doc: LintDocument = .{
            .path = try gpa.dupe(u8, path),
            .handle = handle,
            .analyser = try gpa.create(zls.Analyser),
        };

        doc.analyser.* = switch (version.zig) {
            .@"0.14" => zls.Analyser.init(
                gpa,
                &self.document_store,
                &self.intern_pool,
                handle,
            ),
            .@"0.15" => zls.Analyser.init(
                gpa,
                arena,
                &self.document_store,
                &self.intern_pool,
                handle,
            ),
        };
        return doc;
    }
};

pub const LintOptions = struct {
    config: ?*anyopaque = null,

    pub inline fn getConfig(self: @This(), T: type) T {
        return if (self.config) |config| @as(*T, @ptrCast(@alignCast(config))).* else T{};
    }
};

/// A linter rule with a unique id and a run method.
pub const LintRule = struct {
    rule_id: []const u8,
    run: *const fn (
        self: LintRule,
        ctx: LintContext,
        doc: LintDocument,
        allocator: std.mem.Allocator,
        options: LintOptions,
    ) error{OutOfMemory}!?LintResult,
};

/// Rules the modify the execution of rules.
pub const LintRuleOptions = struct {}; // zlinter-disable-current-line

/// Location of a source file to lint
pub const LintFile = struct {
    /// Path to the file relative to the execution of the linter. This memory
    /// is owned and free'd in `deinit`.
    pathname: []const u8,

    /// Whether or not the path was resolved but subsequently excluded by
    /// an exclude path argument. If this is true, the file should NOT be linted
    excluded: bool = false,

    pub fn deinit(self: *LintFile, allocator: std.mem.Allocator) void {
        allocator.free(self.pathname);
    }
};

pub fn isLintableFilePath(file_path: []const u8) !bool {
    // TODO: Should we support gitignore parsing?
    const extension = ".zig";

    const basename = std.fs.path.basename(file_path);
    if (basename.len <= extension.len) return false;
    if (!std.mem.endsWith(u8, basename, extension)) return false;

    var components = try std.fs.path.componentIterator(file_path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".zig-cache")) return false;
        if (std.mem.eql(u8, component.name, "zig-out")) return false;
    }

    return true;
}

test "isLintableFilePath" {
    // Good:
    inline for (&.{
        "a.zig",
        "file.zig",
        "some/path/file.zig",
        "./some/path/file.zig",
    }) |file_path| {
        try std.testing.expect(try isLintableFilePath(testing.paths.posix(file_path)));
    }

    // Bad extensions:
    inline for (&.{
        ".zig",
        "file.zi",
        "file.z",
        "file.",
        "zig",
        "src/.zig",
        "src/zig",
    }) |file_path| {
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));
    }

    // Bad parent directory
    inline for (&.{
        "zig-out/file.zig",
        "./zig-out/file.zig",
        ".zig-cache/file.zig",
        "./parent/.zig-cache/file.zig",
        "/other/parent/.zig-cache/file.zig",
    }) |file_path| {
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));
    }
}

pub const LintFileRenderer = struct {
    const Self = @This();

    lines: [][]const u8,

    pub fn init(allocator: std.mem.Allocator, stream: anytype) !Self {
        var lines = std.ArrayListUnmanaged([]const u8).empty;
        defer lines.deinit(allocator);

        const max_line_bytes = 64 * 1024;
        var buf: [max_line_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        while (true) {
            fbs.reset();
            if (stream.streamUntilDelimiter(
                fbs.writer(),
                '\n',
                fbs.buffer.len,
            )) {
                const output = fbs.getWritten();
                try lines.append(allocator, try allocator.dupe(u8, output));
            } else |err| switch (err) {
                error.EndOfStream => {
                    if (fbs.getWritten().len == 0) {
                        try lines.append(allocator, try allocator.dupe(u8, ""));
                    }
                    break;
                },
                else => |e| return e,
            }
        }

        return .{ .lines = try lines.toOwnedSlice(allocator) };
    }

    /// Renders a given line with a span highlighted with "^" below the line.
    /// The column values are inclusive of "^". e.g., start 0 and end 1 will
    /// put "^" under column 0 and 1. The output will not include a trailing
    /// newline.
    pub fn render(
        self: Self,
        start_line: usize,
        start_column: usize,
        end_line: usize,
        end_column: usize,
        writer: anytype,
    ) !void {
        for (start_line..end_line + 1) |line_index| {
            const is_start = start_line == line_index;
            const is_end = end_line == line_index;
            const is_middle = !is_start and !is_end;

            if (is_middle) {
                try self.renderLine(
                    line_index,
                    0,
                    if (self.lines[line_index].len == 0) 0 else self.lines[line_index].len - 1,
                    writer,
                );
            } else if (is_start and is_end) {
                try self.renderLine(
                    line_index,
                    start_column,
                    end_column,
                    writer,
                );
            } else if (is_start) {
                try self.renderLine(
                    line_index,
                    start_column,
                    if (self.lines[line_index].len == 0) 0 else self.lines[line_index].len - 1,
                    writer,
                );
            } else if (is_end) {
                try self.renderLine(
                    line_index,
                    0,
                    end_column,
                    writer,
                );
            } else {
                @panic("No possible");
            }

            if (!is_end) {
                try writer.writeByte('\n');
            }
        }
    }

    fn renderLine(
        self: Self,
        line: usize,
        column: usize,
        end_column: usize,
        writer: anytype,
    ) !void {
        const lhs_format = " {d} ";
        const line_lhs_max_width = comptime std.fmt.comptimePrint(lhs_format, .{std.math.maxInt(@TypeOf(line))}).len;
        var lhs_buffer: [line_lhs_max_width]u8 = undefined;
        const lhs = std.fmt.bufPrint(&lhs_buffer, lhs_format, .{line + 1}) catch unreachable;

        // LHS of code
        try writer.writeAll(ansi.get(&.{.cyan}));
        try writer.writeAll(lhs);
        try writer.writeAll("| ");
        try writer.writeAll(ansi.get(&.{.reset}));

        // Actual code
        try writer.writeAll(self.lines[line]);
        try writer.writeByte('\n');

        // LHS of arrows to impacted area
        lhs_buffer = @splat(' ');
        try writer.writeAll(ansi.get(&.{.gray}));
        try writer.writeAll(lhs_buffer[0..lhs.len]);
        try writer.writeAll("| ");
        try writer.writeAll(ansi.get(&.{.reset}));

        // Actual arrows
        for (0..column) |_| try writer.writeByte(' ');
        try writer.writeAll(ansi.get(&.{.bold}));
        for (column..end_column + 1) |_| try writer.writeByte('^');
        try writer.writeAll(ansi.get(&.{.reset}));
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
    }
};

test "LintFileRenderer" {
    const data = "123456789\n987654321\n";
    var input = std.io.fixedBufferStream(data);

    var renderer = try LintFileRenderer.init(
        std.testing.allocator,
        input.reader(),
    );
    defer renderer.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(&[3][]const u8{
        "123456789",
        "987654321",
        "",
    }, renderer.lines);

    {
        var output = std.ArrayListUnmanaged(u8).empty;
        defer output.deinit(std.testing.allocator);

        try renderer.render(
            1,
            3,
            1,
            5,
            output.writer(std.testing.allocator),
        );

        try std.testing.expectEqualStrings(
            \\ 2 | 987654321
            \\   |    ^^^
        , output.items);
    }

    {
        var output = std.ArrayListUnmanaged(u8).empty;
        defer output.deinit(std.testing.allocator);

        try renderer.render(
            0,
            3,
            1,
            1,
            output.writer(std.testing.allocator),
        );

        try std.testing.expectEqualStrings(
            \\ 1 | 123456789
            \\   |    ^^^^^^
            \\ 2 | 987654321
            \\   | ^^
        , output.items);
    }
}

pub const LintTextStyleWithSeverity = struct {
    style: LintTextStyle,
    severity: LintProblemSeverity,

    pub const off = LintTextStyleWithSeverity{
        .style = .off,
        .severity = .off,
    };
};

pub const LintTextStyle = enum {
    /// No style check - can be any style
    off,
    /// e.g., TitleCase
    title_case,
    /// e.g., snake_case
    snake_case,
    /// e.g., camelCase
    camel_case,
    /// e.g., MACRO_CASE (aka "upper snake case")
    macro_case,

    /// A basic check if the content is not (obviously) breaking the style convention
    ///
    /// This is imperfect as it doesn't actually check if word boundaries are
    /// correct but good enough for most cases.
    pub inline fn check(self: LintTextStyle, content: []const u8) bool {
        std.debug.assert(content.len > 0);

        return switch (self) {
            .off => true,
            .snake_case => !strings.containsUpper(content),
            .title_case => strings.isCapitalized(content) and !strings.containsUnderscore(content),
            .camel_case => !strings.isCapitalized(content) and !strings.containsUnderscore(content),
            .macro_case => !strings.containsLower(content),
        };
    }

    test "check" {
        // Off:
        inline for (&.{ "snake_case", "camelCase", "TitleCase", "a", "A" }) |content| {
            try std.testing.expect(LintTextStyle.off.check(content));
        }

        // Snake case:
        inline for (&.{ "snake_case", "a", "a_b_c" }) |content| {
            try std.testing.expect(LintTextStyle.snake_case.check(content));
        }

        // Title case:
        inline for (&.{ "TitleCase", "A", "AB" }) |content| {
            try std.testing.expect(LintTextStyle.title_case.check(content));
        }

        // Camel case:
        inline for (&.{ "camelCase", "a", "aB" }) |content| {
            try std.testing.expect(LintTextStyle.camel_case.check(content));
        }

        // Macro case:
        inline for (&.{ "MACRO_CASE", "A", "1", "1B" }) |content| {
            try std.testing.expect(LintTextStyle.macro_case.check(content));
        }
    }

    pub inline fn name(self: LintTextStyle) []const u8 {
        return switch (self) {
            .off => @panic("Style is off so we should never call this method when off"),
            .snake_case => "snake_case",
            .title_case => "TitleCase",
            .camel_case => "camelCase",
            .macro_case => "MACRO_CASE",
        };
    }
};

pub const LintProblemSeverity = enum {
    /// Exit zero
    off,
    /// Exit zero with warning
    warning,
    /// Exit non-zero
    @"error",

    pub inline fn name(
        self: LintProblemSeverity,
        buffer: *[32]u8,
        options: struct { ansi: bool = false },
    ) []const u8 {
        const prefix = if (options.ansi)
            switch (self) {
                .off => unreachable,
                .warning => ansi.get(&.{ .bold, .yellow }),
                .@"error" => ansi.get(&.{ .bold, .red }),
            }
        else
            "";

        const suffix = if (options.ansi) ansi.get(&.{.reset}) else "";

        return switch (self) {
            .off => unreachable,
            .warning => std.fmt.bufPrint(buffer, "{s}warning{s}", .{ prefix, suffix }) catch unreachable,
            .@"error" => std.fmt.bufPrint(buffer, "{s}error{s}", .{ prefix, suffix }) catch unreachable,
        };
    }
};

/// Result from running a lint rule.
pub const LintResult = struct {
    const Self = @This();

    file_path: []const u8,
    problems: []LintProblem,

    /// Initializes a result. Caller must call deinit once done to free memory.
    pub fn init(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        problems: []LintProblem,
    ) error{OutOfMemory}!Self {
        return .{
            .file_path = try allocator.dupe(u8, file_path),
            .problems = problems,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.problems) |err| {
            allocator.free(err.message);
        }
        allocator.free(self.problems);
        allocator.free(self.file_path);
    }
};

pub const LintProblemLocation = struct {
    /// Location in entire source
    offset: usize,
    /// Line number in source (index zero)
    line: usize,
    /// Column on line in source (index zero)
    column: usize,

    pub const zero: LintProblemLocation = .{
        .offset = 0,
        .line = 0,
        .column = 0,
    };

    pub fn startOfNode(tree: std.zig.Ast, index: std.zig.Ast.Node.Index) LintProblemLocation {
        const first_token_loc = tree.tokenLocation(0, tree.firstToken(index));
        return .{
            .offset = first_token_loc.line_start,
            .line = first_token_loc.line,
            .column = first_token_loc.column,
        };
    }

    pub fn endOfNode(tree: std.zig.Ast, index: std.zig.Ast.Node.Index) LintProblemLocation {
        const last_token = tree.lastToken(index);
        const last_token_loc = tree.tokenLocation(0, last_token);
        return .{
            .offset = last_token_loc.line_end,
            .line = last_token_loc.line,
            .column = last_token_loc.column + tree.tokenSlice(last_token).len,
        };
    }

    pub fn startOfToken(tree: std.zig.Ast, index: std.zig.Ast.TokenIndex) LintProblemLocation {
        const loc = tree.tokenLocation(0, index);
        return .{
            .offset = loc.line_start,
            .line = loc.line,
            .column = loc.column,
        };
    }

    pub fn endOfToken(tree: std.zig.Ast, index: std.zig.Ast.TokenIndex) LintProblemLocation {
        const loc = tree.tokenLocation(0, index);
        return .{
            .offset = loc.line_end,
            .line = loc.line,
            .column = loc.column + tree.tokenSlice(index).len - 1,
        };
    }

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = undefined;
        @memset(&spaces, ' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .offset = {d},\n", .{ indent_str, self.offset });
        writer.print("{s}  .line = {d},\n", .{ indent_str, self.line });
        writer.print("{s}  .column = {d},\n", .{ indent_str, self.column });
        writer.print("{s}}},\n", .{indent_str});
    }
};

pub const LintProblem = struct {
    const Self = @This();

    rule_id: []const u8,
    severity: LintProblemSeverity,
    start: LintProblemLocation,
    end: LintProblemLocation,

    message: []const u8,
    disabled_by_comment: bool = false,
    fix: ?LintProblemFix = null,

    pub fn sliceSource(self: Self, source: [:0]const u8) []const u8 {
        return source[self.start.offset..self.end.offset];
    }

    pub fn debugPrint(self: Self, writer: anytype) void {
        writer.print(".{{\n", .{});
        writer.print("  .rule_id = \"{s}\",\n", .{self.rule_id});
        writer.print("  .severity = .@\"{s}\",\n", .{@tagName(self.severity)});
        writer.print("  .start =\n", .{});
        self.start.debugPrintWithIndent(writer, 4);

        writer.print("  .end =\n", .{});
        self.end.debugPrintWithIndent(writer, 4);

        writer.print("  .message = \"{s}\",\n", .{self.message});
        writer.print("  .disabled_by_comment = {?},\n", .{self.disabled_by_comment});

        if (self.fix) |fix| {
            writer.print("  .fix =\n", .{});
            fix.debugPrintWithIndent(writer, 4);
        } else {
            writer.print("  .fix = null,\n", .{});
        }

        writer.print("}},\n", .{});
    }
};

pub const LintProblemFix = struct {
    start: usize,
    end: usize,
    text: []const u8,

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = undefined;
        @memset(&spaces, ' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .start = {d},\n", .{ indent_str, self.start });
        writer.print("{s}  .end = {d},\n", .{ indent_str, self.end });
        writer.print("{s}  .text = \"{s}\",\n", .{ indent_str, self.text });
        writer.print("{s}}},\n", .{indent_str});
    }
};

test "LintDocument.resolveTypeKind" {
    const TestCase = struct {
        contents: [:0]const u8,
        kind: ?LintDocument.TypeKind,
    };

    for ([_]TestCase{
        // Other:
        // ------
        .{
            .contents = "var ok:u32 = 10;",
            .kind = .other,
        },
        .{
            .contents = "age:u8 = 10,",
            .kind = .other,
        },
        .{
            .contents = "name :[] const u8,",
            .kind = .other,
        },
        // Type:
        // -----
        .{
            .contents = "const A: type = u32;",
            .kind = .type,
        },
        .{
            .contents = "const A = u32;",
            .kind = .type,
        },
        .{
            .contents = "const A:?type = u32;",
            .kind = .type,
        },
        .{
            .contents = "const A:?type = null;",
            .kind = .type,
        },
        .{
            .contents = "const A = @TypeOf(u32);",
            .kind = .type,
        },
        .{
            .contents =
            \\const A = BuildType();
            \\fn BuildType() type {
            \\   return u32;
            \\}
            ,
            .kind = .type,
        },
        // Struct type:
        // ------------
        .{
            .contents =
            \\const A = BuildType();
            \\fn BuildType() type {
            \\   return struct { field: u32 };
            \\}
            ,
            .kind = .struct_type,
        },
        .{
            .contents = "const A = struct { field: u32; };",
            .kind = .struct_type,
        },
        // Namespace type:
        // ---------------
        .{
            .contents = "const a = struct { const decl: u32 = 1; };",
            .kind = .namespace_type,
        },
        .{
            .contents =
            \\const a = struct {
            \\   pub fn hello() []const u8 {
            \\      return "Hello";
            \\   }
            \\};
            ,
            .kind = .namespace_type,
        },
        // Namespace instance (invalid use)
        // --------------------------------
        .{
            .contents =
            \\ const pointless = my_namespace{};
            \\ const my_namespace = struct { const decl: u32 = 1; };
            ,
            .kind = null,
        },
        // Function:
        // ---------------
        .{
            .contents = "var a: fn () void = undefined;",
            .kind = .@"fn",
        },
        .{
            .contents =
            \\var a = &func;
            \\fn func() u32 {
            \\  return 10;
            \\}
            ,
            .kind = .@"fn",
        },
        // Type that is function
        .{
            .contents = "var a = fn() void;",
            .kind = .fn_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = fn() void;
            ,
            .kind = .fn_type,
        },
        .{
            .contents = "var a = *const fn() void;",
            .kind = .fn_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = *const fn() void;
            ,
            .kind = .fn_type,
        },
        // Type that is function that returns type
        .{
            .contents = "var a = fn() type;",
            .kind = .fn_type_returns_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = fn() type;
            ,
            .kind = .fn_type_returns_type,
        },
        .{
            .contents = "var a = *const fn() type;",
            .kind = .fn_type_returns_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = *const fn() type;
            ,
            .kind = .fn_type_returns_type,
        },
        // Function that returns type
        .{
            .contents =
            \\var a = &func;
            \\fn func() type {
            \\  return f32;
            \\}
            ,
            .kind = .fn_returns_type,
        },
        .{
            .contents =
            \\var a: *const fn () type = undefined;
            ,
            .kind = .fn_returns_type,
        },
        // Error type
        .{
            .contents =
            \\var MyError = error {a,b,c};
            ,
            .kind = .error_type,
        },
        // TODO: Fix this and add test with error union
        // .{
        //     .contents =
        //     \\var MyError = Reference;
        //     \\const Reference = error {a,b,c}
        //     ,
        //     .kind = .error_type,
        // },

        // Error instance
        .{
            .contents =
            \\const err = error.MyError;
            ,
            // TODO: This should be error_instance but for now its other
            .kind = .other,
        },
        // Union instance:
        .{
            .contents =
            \\const u = U{.a=1};
            \\const U = union { a: u32, b: f32 };
            ,
            .kind = .union_instance,
        },
        .{
            .contents =
            \\const a = u;
            \\const u = U{.a=1};
            \\const U = union { a: u32, b: f32 };
            ,
            .kind = .union_instance,
        },
        // Struct instance:
        .{
            .contents =
            \\const s = S{.a=1};
            \\const S = struct { a: u32  };
            ,
            .kind = .struct_instance,
        },
        .{
            .contents =
            \\const a = s;
            \\const s = S{.a=1};
            \\const S = struct { a: u32 };
            ,
            .kind = .struct_instance,
        },
        // Struct instance:
        .{
            .contents =
            \\const s = E.a;
            \\const E = enum { a, b  };
            ,
            .kind = .enum_instance,
        },
        .{
            .contents =
            \\const a = s;
            \\const s = E.a;
            \\const E = enum { a, b };
            ,
            .kind = .enum_instance,
        },
        // Opaque type
        .{
            .contents =
            \\const Window = opaque {
            \\  fn show(self: *Window) void {
            \\    show_window(self);
            \\  }
            \\};
            \\
            \\extern fn show_window(*Window) callconv(.C) void;
            ,
            .kind = .opaque_type,
        },
        // Opaque instance
        .{
            .contents =
            \\var main_window: *Window = undefined;
            \\const Window = opaque {
            \\  fn show(self: *Window) void {
            \\    show_window(self);
            \\  }
            \\};
            \\
            \\extern fn show_window(*Window) callconv(.C) void;
            ,
            // TODO: This should be opaque_instance but for now its other
            .kind = .other,
        },
    }) |test_case| {
        var ctx: LintContext = undefined;
        try ctx.init(.{}, std.testing.allocator);
        defer ctx.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var doc = (try testing.loadFakeDocument(
            &ctx,
            tmp.dir,
            "test.zig",
            test_case.contents,
            arena.allocator(),
        )).?;
        defer doc.deinit(ctx.gpa);

        const node = doc.handle.tree.rootDecls()[0];
        const actual_kind = if (doc.handle.tree.fullVarDecl(node)) |var_decl|
            try doc.resolveTypeKind(.{ .var_decl = var_decl })
        else if (doc.handle.tree.fullContainerField(node)) |container_field|
            try doc.resolveTypeKind(.{ .container_field = container_field })
        else
            @panic("Fail");

        std.testing.expectEqual(test_case.kind, actual_kind) catch |e| {
            const border: [50]u8 = @splat('-');
            var writer = std.io.getStdErr().writer();
            try writer.print("Node:\n{s}\n{s}\n{s}\n", .{ border, doc.handle.tree.getNodeSource(node), border });
            try writer.print("Expected: {any}\n", .{test_case.kind});
            try writer.print("Actual: {any}\n", .{actual_kind});
            try writer.print("Contents:\n{s}\n{s}\n{s}\n", .{ border, test_case.contents, border });

            return e;
        };
    }
}

const std = @import("std");
const builtin = @import("builtin");
const zls = @import("zls");
const strings = @import("strings.zig");
const version = @import("version.zig");
const ansi = @import("ansi.zig");
const shims = @import("shims.zig");
const testing = @import("testing.zig");
