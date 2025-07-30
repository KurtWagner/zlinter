//! Linting module for items relating to the linting session (e.g., overall context
//! and document store).

/// A loaded and parsed zig file that is given to zig lint rules.
pub const LintDocument = struct {
    path: []const u8,
    handle: *zls.DocumentStore.Handle,
    analyser: *zls.Analyser,
    lineage: *ast.NodeLineage,
    comments: comments.CommentsDocument,
    skipper: comments.LazyRuleSkipper,

    pub fn deinit(self: *LintDocument, gpa: std.mem.Allocator) void {
        while (self.lineage.pop()) |connections| {
            connections.deinit(gpa);
        }

        self.lineage.deinit(gpa);
        gpa.destroy(self.lineage);

        self.analyser.deinit();
        gpa.destroy(self.analyser);
        gpa.free(self.path);

        self.comments.deinit(gpa);

        self.skipper.deinit();
    }

    pub fn shouldSkipProblem(self: *@This(), problem: LintProblem) error{OutOfMemory}!bool {
        return self.skipper.shouldSkip(problem);
    }

    pub inline fn resolveTypeOfNode(self: @This(), node: std.zig.Ast.Node.Index) !?zls.Analyser.Type {
        return switch (version.zig) {
            .@"0.15" => self.analyser.resolveTypeOfNode(.of(node, self.handle)),
            .@"0.14" => self.analyser.resolveTypeOfNode(.{ .handle = self.handle, .node = node }),
        };
    }

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

        pub fn name(self: TypeKind) []const u8 {
            return switch (self) {
                .other => "Other",
                .@"fn" => "Function",
                .fn_returns_type => "Type function",
                .opaque_instance => "Opaque instance",
                .enum_instance => "Enum instance",
                .struct_instance => "Struct instance",
                .union_instance => "Union instance",
                .error_type => "Error",
                .fn_type => "Function type",
                .fn_type_returns_type => "Type function type",
                .type => "Type",
                .enum_type => "Enum",
                .struct_type => "Struct",
                .namespace_type => "Namespace",
                .union_type => "Union",
                .opaque_type => "Opaque",
            };
        }
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
                .error_set_decl,
                .merge_error_sets,
                => return .error_type,
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

                            if (!shims.NodeIndexShim.init(container_node).isRoot()) {
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
                } else if (decl.isMetaType()) {
                    return .type;
                } else {
                    if (init_node_type.is_type_val) {
                        switch (init_node_type.data) {
                            .ip_index => return .type,
                            .other => |node_with_handle| {
                                switch (shims.nodeTag(node_with_handle.handle.tree, node_with_handle.node)) {
                                    .merge_error_sets => return .error_type,
                                    else => {},
                                }
                            },
                            else => {},
                        }
                    }
                    return .other;
                }
            }
        }
        return null;
    }

    /// Walks up from a current node up its ansesters (e.g., parent,
    /// grandparent, etc) until it reaches the root node of the document.
    ///
    /// This will not include the given node, only its ancestors.
    pub fn nodeAncestorIterator(
        self: LintDocument,
        node: std.zig.Ast.Node.Index,
    ) ast.NodeAncestorIterator {
        return .{
            .current = shims.NodeIndexShim.init(node),
            .lineage = self.lineage,
        };
    }

    pub fn nodeLineageIterator(
        self: LintDocument,
        node: shims.NodeIndexShim,
        gpa: std.mem.Allocator,
    ) error{OutOfMemory}!ast.NodeLineageIterator {
        var it = ast.NodeLineageIterator{
            .gpa = gpa,
            .queue = .empty,
            .lineage = self.lineage,
        };
        try it.queue.append(gpa, node);
        return it;
    }

    /// Returns true if the given node appears within a `test {..}` declaration
    /// block.
    pub fn isEnclosedInTestBlock(self: LintDocument, node: shims.NodeIndexShim) bool {
        var next = node;
        while (self.lineage.items(.parent)[next.index]) |parent| {
            switch (shims.nodeTag(self.handle.tree, parent)) {
                .test_decl => return true,
                else => next = shims.NodeIndexShim.init(parent),
            }
        }
        return false;
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
            .thread_pool = undefined, // zlinter-disable-current-line no_undefined - set below
            .document_store = undefined, // zlinter-disable-current-line no_undefined - set below
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

        const lineage = try gpa.create(ast.NodeLineage);
        lineage.* = .empty;

        const handle = self.document_store.getOrLoadHandle(uri) orelse return null;
        var doc: LintDocument = .{
            .path = try gpa.dupe(u8, path),
            .handle = handle,
            .analyser = try gpa.create(zls.Analyser),
            .lineage = lineage,
            .comments = try comments.allocParse(handle.tree.source, gpa),
            .skipper = undefined, // zlinter-disable-current-line no_undefined - set below
        };
        doc.skipper = .init(doc.comments, doc.handle.tree.source, gpa);

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

        {
            try doc.lineage.resize(gpa, doc.handle.tree.nodes.len);
            for (0..doc.handle.tree.nodes.len) |i| {
                doc.lineage.set(i, .{});
            }

            const QueueItem = struct {
                parent: ?shims.NodeIndexShim = null,
                node: shims.NodeIndexShim,
            };

            var queue = std.ArrayList(QueueItem).init(gpa);
            defer queue.deinit();

            try queue.append(.{ .node = shims.NodeIndexShim.root });

            while (queue.pop()) |item| {
                const children = try ast.nodeChildrenAlloc(
                    gpa,
                    doc.handle.tree,
                    item.node.toNodeIndex(),
                );

                // Ideally this is never necessary as we should only be visiting
                // each node once while walking the tree and if we're not there's
                // another bug but for now to be safe memory wise we'll ensure
                // the previous is cleaned up if needed (no-op if not needed)
                doc.lineage.get(item.node.index).deinit(gpa);
                doc.lineage.set(item.node.index, .{
                    .parent = if (item.parent) |p|
                        p.toNodeIndex()
                    else
                        null,
                    .children = children,
                });

                for (children) |child| {
                    try queue.append(.{
                        .parent = item.node,
                        .node = shims.NodeIndexShim.init(child),
                    });
                }
            }
        }
        return doc;
    }
};

pub const LintOptions = struct {
    config: ?*anyopaque = null,

    pub inline fn getConfig(self: @This(), T: type) T {
        return if (self.config) |config| @as(*T, @ptrCast(@alignCast(config))).* else T{};
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
        .{
            .contents =
            \\var MyError = some.other.errors || OtherErrors;
            ,
            .kind = .error_type,
        },
        .{
            .contents =
            \\var MyError = Reference;
            \\const Reference = error {a,b,c};
            ,
            .kind = .error_type,
        },
        // Error instance
        .{
            .contents =
            \\const err = error.MyError;
            ,
            .kind = .other,
        },
        .{
            .contents =
            \\var MyError:error{a} = other;
            ,
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
const version = @import("version.zig");
const shims = @import("shims.zig");
const testing = @import("testing.zig");
const ast = @import("ast.zig");
const comments = @import("comments.zig");
const LintProblem = @import("results.zig").LintProblem;
