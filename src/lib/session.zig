//! Linting module for items relating to the linting session (e.g., overall context
//! and document store).

pub const max_zig_file_size_bytes = bytes: {
    const bytes_in_mb = 1024 * 1024;
    break :bytes 32 * bytes_in_mb;
};

/// A loaded and parsed zig file that is given to zig lint rules.
pub const LintDocument = struct {
    path: []const u8,
    handle: *zls.DocumentStore.Handle,
    lineage: ast.NodeLineage,
    comments: comments.CommentsDocument,
    skipper: comments.LazyRuleSkipper,

    pub fn deinit(self: *LintDocument, gpa: std.mem.Allocator) void {
        while (self.lineage.pop()) |connections| {
            connections.deinit(gpa);
        }

        self.lineage.deinit(gpa);

        gpa.free(self.path);

        self.comments.deinit(gpa);

        self.skipper.deinit();
    }

    /// Returns true if the problem should be skipped based on line level
    /// disable comments.
    pub fn shouldSkipProblem(self: *LintDocument, problem: LintProblem) error{OutOfMemory}!bool {
        return self.skipper.shouldSkip(problem);
    }

    /// Walks up from a current node up its ansesters (e.g., parent,
    /// grandparent, etc) until it reaches the root node of the document.
    ///
    /// This will not include the given node, only its ancestors.
    pub fn nodeAncestorIterator(
        self: *const LintDocument,
        node: Ast.Node.Index,
    ) ast.NodeAncestorIterator {
        return .{
            .current = NodeIndexShim.init(node),
            .lineage = &self.lineage,
        };
    }

    /// Walks down from the current node does its children.
    ///
    /// This includes the given node in the traversal.
    pub fn nodeLineageIterator(
        self: *const LintDocument,
        node: NodeIndexShim,
        gpa: std.mem.Allocator,
    ) error{OutOfMemory}!ast.NodeLineageIterator {
        var it = ast.NodeLineageIterator{
            .gpa = gpa,
            .queue = .empty,
            .lineage = &self.lineage,
        };
        try it.queue.append(gpa, node);
        return it;
    }

    /// Returns true if the given node appears within a `test {..}` declaration
    /// block or a `if (builtin.is_test) {..}` block.
    ///
    /// This is an imperfect heuristic but should be good enough for majority
    /// of cases. A more complete solution would require building tests and
    /// seeing whats included thats not in non-test builds, which is probably
    /// out of scope for this linter.
    pub fn isEnclosedInTestBlock(self: *const LintDocument, node: NodeIndexShim) bool {
        var next = node;
        while (self.lineage.items(.parent)[next.index]) |parent| {
            switch (shims.nodeTag(self.handle.tree, parent)) {
                .test_decl => return true,
                .@"if", .if_simple => if (isTestOnlyCondition(
                    self.handle.tree,
                    self.handle.tree.fullIf(parent).?,
                )) {
                    return true;
                },
                else => {},
            }
            next = NodeIndexShim.init(parent);
        }
        return false;
    }

    /// For debugging purposes only, should never be left in
    pub fn dumpType(self: *const LintDocument, t: zls.Analyser.Type, indent_size: u32) !void {
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

/// Returns true if the if statement appears to enforce that its block is test only
fn isTestOnlyCondition(tree: Ast, if_statement: Ast.full.If) bool {
    const cond_node = if_statement.ast.cond_expr;
    return switch (shims.nodeTag(tree, cond_node)) {
        .identifier => std.mem.eql(u8, "is_test", tree.getNodeSource(cond_node)),
        .field_access => ast.isFieldVarAccess(tree, cond_node, &.{"is_test"}),
        else => false,
    };
}

/// The context of all document and rule executions.
pub const LintContext = struct {
    environ_map: *const std.process.Environ.Map,
    diagnostics_collection: zls.DiagnosticsCollection,
    intern_pool: zls.analyser.InternPool,
    document_store: zls.DocumentStore,
    gpa: std.mem.Allocator,
    analyser: zls.Analyser,
    io: std.Io,

    pub fn init(
        self: *LintContext,
        config: zls.Config,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
    ) !void {
        self.* = .{
            .gpa = gpa,
            .diagnostics_collection = .{
                .allocator = gpa,
                .io = io,
            },
            .intern_pool = try .init(gpa),
            .document_store = undefined, // zlinter-disable-current-line no_undefined - set below
            .analyser = undefined, // zlinter-disable-current-line no_undefined - set below
            .io = io,
            .environ_map = environ_map,
        };
        errdefer self.intern_pool.deinit(gpa);

        self.document_store = zls.DocumentStore{
            .io = io,
            .allocator = gpa,
            .diagnostics_collection = &self.diagnostics_collection,
            .config = .{
                .environ_map = environ_map,
                .zig_exe_path = config.zig_exe_path,
                .zig_lib_dir = dir: {
                    if (config.zig_lib_path) |zig_lib_path| {
                        if (std.Io.Dir.openDirAbsolute(io, zig_lib_path, .{})) |zig_lib_dir| {
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
                        if (std.Io.Dir.openDirAbsolute(io, global_cache_path, .{})) |global_cache_dir| {
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
                .wasi_preopens = switch (builtin.os.tag) {
                    .wasi => try std.fs.wasi.preopensAlloc(arena),
                    else => {},
                },
            },
        };

        self.analyser = switch (version.zig) {
            .@"0.14" => zls.Analyser.init(
                gpa,
                &self.document_store,
                &self.intern_pool,
                null,
            ),
            .@"0.15", .@"0.16" => zls.Analyser.init(
                gpa,
                arena,
                &self.document_store,
                &self.intern_pool,
                null,
            ),
        };
    }

    pub fn deinit(self: *LintContext) void {
        self.diagnostics_collection.deinit();
        self.intern_pool.deinit(self.gpa);
        self.document_store.deinit();
        self.analyser.deinit();
    }

    /// Loads and parses zig file into the document store.
    ///
    /// Caller is responsible for calling deinit once done.
    pub fn initDocument(
        self: *LintContext,
        path: []const u8,
        gpa: std.mem.Allocator,
        doc: *LintDocument,
    ) !void {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const size = try std.Io.Dir.cwd().realPathFile(
            self.io,
            path,
            &buffer,
        );

        var mem: [std.fs.max_path_bytes]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&mem);

        const uri = try zls.Uri.fromPath(
            fba.allocator(),
            buffer[0..size],
        );

        const handle = self.document_store.getOrLoadHandle(uri) orelse return error.HandleError;

        var src_comments = try comments.allocParse(handle.tree.source, gpa);
        errdefer src_comments.deinit(gpa);

        doc.* = .{
            .path = try gpa.dupe(u8, path),
            .handle = handle,
            .lineage = .empty,
            .comments = src_comments,
            .skipper = undefined, // zlinter-disable-current-line no_undefined - set below
        };
        errdefer gpa.free(doc.path);
        errdefer doc.lineage.deinit(gpa);

        doc.skipper = .init(doc.comments, doc.handle.tree.source, gpa);
        errdefer doc.skipper.deinit();

        {
            try doc.lineage.resize(gpa, doc.handle.tree.nodes.len);
            for (0..doc.handle.tree.nodes.len) |i| {
                doc.lineage.set(i, .{});
            }

            const QueueItem = struct {
                parent: ?NodeIndexShim = null,
                node: NodeIndexShim,
            };

            var queue = shims.ArrayList(QueueItem).empty;
            defer queue.deinit(gpa);

            try queue.append(gpa, .{ .node = NodeIndexShim.root });

            while (queue.pop()) |item| {
                const children = try ast.nodeChildrenAlloc(
                    gpa,
                    &doc.handle.tree,
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
                    try queue.append(gpa, .{
                        .parent = item.node,
                        .node = NodeIndexShim.init(child),
                    });
                }
            }
        }
    }

    /// Resolves the type of node or null if it can't be resolved.
    pub fn resolveTypeOfNode(self: *LintContext, doc: *const LintDocument, node: Ast.Node.Index) !?zls.Analyser.Type {
        return switch (version.zig) {
            .@"0.15", .@"0.16" => self.analyser.resolveTypeOfNode(.of(node, doc.handle)),
            .@"0.14" => self.analyser.resolveTypeOfNode(.{ .handle = doc.handle, .node = node }),
        };
    }

    /// Resolves the type of a node that points to a type (e.g., return type) or
    /// null if it cannot be resolved.
    pub fn resolveTypeOfTypeNode(self: *LintContext, doc: *const LintDocument, node: Ast.Node.Index) !?zls.Analyser.Type {
        const resolved_type = try self.resolveTypeOfNode(doc, node) orelse return null;
        const instance_type = if (resolved_type.isMetaType()) resolved_type else switch (version.zig) {
            .@"0.14" => resolved_type.instanceTypeVal(&self.analyser) orelse resolved_type,
            .@"0.15", .@"0.16" => try resolved_type.instanceTypeVal(&self.analyser) orelse resolved_type,
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
    pub fn resolveTypeKind(self: *LintContext, doc: *const LintDocument, input: union(enum) {
        var_decl: Ast.full.VarDecl,
        container_field: Ast.full.ContainerField,
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
                NodeIndexShim.initOptional(t),
                NodeIndexShim.initOptional(v),
            };
        };

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        var fn_proto_buffer: [1]Ast.Node.Index = undefined;

        const tree = doc.handle.tree;

        // First we try looking for a <type> node in the declaration. e.g.,
        // `const var_name: <type> = ....`
        if (maybe_type_node) |type_node| {
            const node = shims.unwrapNode(tree, type_node.toNodeIndex(), .{});

            if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
                if (NodeIndexShim.initOptional(fn_proto.ast.return_type)) |return_node_shim| {
                    const return_node = shims.unwrapNode(tree, return_node_shim.toNodeIndex(), .{});

                    // If it's a function proto, then return whether or not the function returns `type`
                    const is_type_identifier = shims.isIdentiferKind(tree, shims.unwrapNode(tree, return_node, .{}), .type);
                    return if (is_type_identifier) .fn_returns_type else .@"fn";
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
            } else if (try self.resolveTypeOfNode(doc, node)) |type_node_type| {
                const decl = type_node_type.resolveDeclLiteralResultType();

                return if (decl.isUnionType())
                    .union_instance
                else if (decl.isEnumType())
                    .enum_instance
                else if (decl.isStructType())
                    .struct_instance
                else if (decl.isTypeFunc())
                    .fn_returns_type
                else if (decl.isFunc())
                    .@"fn"
                else if (isTypeUnknown(type_node_type))
                    null
                else
                    .other;
            }
        }

        // Then we look at the initialisation <value> if a type couldn't be used
        // from then declaration. e.g., `const var_name = <value>`
        if (maybe_value_node) |value_node| {
            const node = shims.unwrapNode(tree, value_node.toNodeIndex(), .{});

            // LIMITATION: All builtin calls to type of and type will return
            // `type` without any resolution.
            switch (shims.nodeTag(tree, node)) {
                .builtin_call_two,
                .builtin_call_two_comma,
                .builtin_call,
                .builtin_call_comma,
                => inline for (&.{ "@Type", "@TypeOf" }) |builtin_name| {
                    if (std.mem.eql(u8, builtin_name, tree.tokenSlice(shims.nodeMainToken(tree, node)))) {
                        return .type;
                    }
                },
                .error_set_decl,
                .merge_error_sets,
                => return .error_type,
                else => {},
            }

            if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
                return switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
                    .keyword_struct => if (shims.isContainerNamespace(tree, container_decl)) .namespace_type else .struct_type,
                    .keyword_union => .union_type,
                    .keyword_opaque => .opaque_type,
                    .keyword_enum => .enum_type,
                    inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
                };
            } else if (try self.resolveTypeOfNode(doc, node)) |init_node_type| {
                const decl = init_node_type.resolveDeclLiteralResultType();

                const is_error_container =
                    if (std.meta.hasMethod(@TypeOf(decl), "isErrorSetType"))
                        decl.isErrorSetType(&self.analyser)
                    else switch (decl.data) {
                        .container => |container| result: {
                            const container_node, const container_tree = switch (version.zig) {
                                .@"0.14" => .{ container.toNode(), container.handle.tree },
                                .@"0.15", .@"0.16" => .{ container.scope_handle.toNode(), container.scope_handle.handle.tree },
                            };

                            if (!NodeIndexShim.init(container_node).isRoot()) {
                                switch (shims.nodeTag(container_tree, container_node)) {
                                    .error_set_decl => break :result true,
                                    else => {},
                                }
                            }
                            break :result false;
                        },
                        else => false,
                    };

                const is_type_val = init_node_type.is_type_val;
                return if (is_error_container)
                    .error_type
                else if (decl.isNamespace())
                    if (is_type_val) .namespace_type else null
                else if (decl.isUnionType())
                    if (is_type_val) .union_type else .union_instance
                else if (decl.isEnumType())
                    if (is_type_val) .enum_type else .enum_instance
                else if (decl.isOpaqueType())
                    if (is_type_val) .opaque_type else null
                else if (decl.isStructType())
                    if (is_type_val) .struct_type else .struct_instance
                else if (decl.isTypeFunc())
                    if (is_type_val) .fn_type_returns_type else .fn_returns_type
                else if (decl.isFunc())
                    if (is_type_val) .fn_type else .@"fn"
                else if (decl.isMetaType())
                    .type
                else if (is_type_val)
                    if (init_node_type.isErrorSetType(&self.analyser))
                        .error_type
                    else switch (init_node_type.data) {
                        // TODO: Maybe this can be merged with what isErrorSet
                        // is doing to be less branches.
                        .ip_index => .type,
                        else => null,
                    }
                else if (try self.isCallReturningType(doc.handle, node))
                    return .type
                else if (isTypeUnknown(init_node_type))
                    return null
                else
                    return .other;
            }
        }

        return null;
    }

    /// Returns true if a resolved type is unknown. Typically this means that
    /// a linter should ignore any checks that rely on a type (e.g., naming styles)
    fn isTypeUnknown(node_type: zls.Analyser.Type) bool {
        return switch (node_type.data) {
            .ip_index => |info| info.type == .unknown_type or
                info.type == .unknown_unknown,
            else => false,
        };
    }

    /// Returns true if it's a call to a function that returns `type`.
    ///
    /// For example:
    ///
    /// ```
    /// const MyType = BuildType();
    /// //             ~~~~~~~~~~~  <---- this node would return true
    ///
    /// fn BuildType() type {
    ///   return struct {
    ///     // ...
    ///   };
    /// }
    /// ```
    ///
    /// Returns false if not a call or if the call is to a function that does
    /// not return `type`.
    fn isCallReturningType(
        self: *LintContext,
        handle: *zls.DocumentStore.Handle,
        node: Ast.Node.Index,
    ) !bool {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();

        const child = (try self.resolveFnDecl(
            handle,
            node,
            arena.allocator(),
        )) orelse return false;

        var fn_buffer: [1]Ast.Node.Index = undefined;
        const return_type = child.handle.tree.fullFnProto(
            &fn_buffer,
            child.decl.ast_node,
        ).?.ast.return_type.unwrap() orelse return false;
        return child.handle.tree.nodeTag(return_type) == .identifier and
            std.mem.eql(u8, child.handle.tree.getNodeSource(return_type), "type");
    }

    /// Resolves the declaration of a function from a function call.
    ///
    /// If the given node is not a function call this method will return null.
    fn resolveFnDecl(
        self: *LintContext,
        handle: *zls.DocumentStore.Handle,
        call_node: Ast.Node.Index,
        arena: std.mem.Allocator,
    ) !?zls.Analyser.DeclWithHandle {
        // Return null if not even a function call node.
        var call_buffer: [1]Ast.Node.Index = undefined;
        const call = handle.tree.fullCall(&call_buffer, call_node) orelse
            return null;

        // Walk down symbols until we reach a function.
        var child: zls.Analyser.DeclWithHandle = (try self.resolveDecl(
            handle,
            call.ast.fn_expr,
            arena,
        )) orelse return null;

        walking: while (true) {
            if (child.decl != .ast_node) break :walking;

            if (child.handle.tree.fullVarDecl(child.decl.ast_node)) |decl| {
                if (decl.ast.init_node.unwrap()) |init_node| {
                    child = try self.resolveDecl(
                        child.handle,
                        init_node,
                        arena,
                    ) orelse break :walking;
                    continue :walking;
                }
                break :walking;
            }

            const is_fn_proto = switch (child.handle.tree.nodeTag(child.decl.ast_node)) {
                .fn_proto,
                .fn_proto_multi,
                .fn_proto_one,
                .fn_proto_simple,
                .fn_decl,
                => true,
                else => false,
            };
            if (is_fn_proto)
                return child
            else
                break :walking;
        }
        return null;
    }

    /// Resolves the declaration for a given node (aka symbol).
    ///
    /// Only supports identifiers and field access ending in an identifier.
    fn resolveDecl(
        self: *LintContext,
        handle: *zls.DocumentStore.Handle,
        node: Ast.Node.Index,
        arena: std.mem.Allocator,
    ) !?zls.Analyser.DeclWithHandle {
        const tree = handle.tree;

        return switch (tree.nodeTag(node)) {
            .identifier => try self.analyser.lookupSymbolGlobal(
                handle,
                tree.getNodeSource(node),
                tree.tokenStart(tree.firstToken(node)),
            ),
            .field_access => field_access: {
                const first_token = tree.firstToken(node);
                const last_token = tree.lastToken(node);

                const held_loc: std.zig.Token.Loc = .{
                    .start = tree.tokenStart(first_token),
                    .end = tree.tokenStart(last_token) + tree.tokenSlice(last_token).len,
                };

                const identifier_token = last_token;
                if (tree.tokenTag(identifier_token) != .identifier)
                    break :field_access null;

                if (try self.analyser.getSymbolFieldAccesses(
                    arena,
                    handle,
                    tree.tokenStart(identifier_token),
                    held_loc,
                    tree.tokenSlice(identifier_token),
                )) |decls| {
                    if (decls.len > 0) break :field_access decls[0];
                }
                break :field_access null;
            },
            else => symbol: {
                std.log.warn("Unhandled: {}", .{tree.nodeTag(node)});
                break :symbol null;
            },
        };
    }

    /// Resolves the resulting type of an either expression (e.g., switch statement in an assignment)
    fn resolveEitherType(_: *LintContext, _: []const zls.Analyser.Type.Data.EitherEntry) zls.Analyser.Type {
        @panic("Not implemented yet");
    }
};

test "LintDocument.isEnclosedInTestBlock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const environ_map: std.process.Environ.Map = .init(arena.allocator());

    var context: LintContext = undefined;
    try context.init(.{}, std.testing.io, &environ_map, std.testing.allocator, arena.allocator());
    defer context.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\pub fn main() void {
        \\ const is_not_in_test = 1;
        \\
        \\ if (builtin.is_test) {
        \\  const is_in_test_if_condition_a = 1;  
        \\ }
        \\ if (anything.is_test) {
        \\  const is_in_test_if_condition_b = 1;
        \\ }
        \\ if (is_test) {
        \\  const is_in_test_if_condition_c = 1;
        \\ }
        \\ if (something) {
        \\    const is_not_in_test_nested_if_condition_a = 1;
        \\    if (is_test) {
        \\      const is_in_test_nested_if_condition_a = 1;
        \\    }
        \\ }
        \\ if (is_test) {
        \\    const is_in_test_nested_if_condition_c = 1;
        \\    if (something) {
        \\      const is_in_test_nested_if_condition_b = 1;
        \\    }
        \\ }
        \\ if (other) {
        \\  const is_not_in_test_if_condition = 1;
        \\ }
        \\}
        \\
        \\test {
        \\ const is_in_test_without_name = 1;
        \\}
        \\
        \\test "with name" {
        \\ const is_in_test_with_name = 1;
        \\}
    ;

    const doc = try testing.loadFakeDocument(
        &context,
        tmp.dir,
        "test.zig",
        source,
        arena.allocator(),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_without_name",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_a",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_b",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_c",
        ))),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test_if_condition",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_a",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_b",
        ))),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_c",
        ))),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(.init(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test_nested_if_condition_a",
        ))),
    );
}

test "LintContext.resolveTypeKind" {
    const TestCase = struct {
        contents: [:0]const u8,
        kind: ?LintContext.TypeKind,
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
        .{
            .contents =
            \\const FloatType = IntToFloatType(u32);
            \\fn IntToFloatType(IntType: type) type {
            \\return @Type(.{
            \\    .int = .{
            \\        .signedness = .signed,
            \\        .bits = @typeInfo(IntType).float.bits,
            \\    },
            \\});
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
            .contents = "const A = struct { field: u32 };",
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
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        const environ_map: std.process.Environ.Map = .init(arena.allocator());

        var context: LintContext = undefined;
        try context.init(.{}, std.testing.io, &environ_map, std.testing.allocator, arena.allocator());
        defer context.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            test_case.contents,
            arena.allocator(),
        );
        std.testing.expectEqual(doc.handle.tree.errors.len, 0) catch |err| {
            std.debug.print("Failed to parse AST:\n{s}\n", .{test_case.contents});
            for (doc.handle.tree.errors) |ast_err| {
                var buffer: [1024]u8 = undefined;

                var writer = std.Io.File.stderr().writer(std.testing.io, &buffer).interface;
                try doc.handle.tree.renderError(ast_err, &writer);
                try writer.flush();
            }
            return err;
        };

        const node = doc.handle.tree.rootDecls()[0];
        const actual_kind = if (doc.handle.tree.fullVarDecl(node)) |var_decl|
            try context.resolveTypeKind(doc, .{ .var_decl = var_decl })
        else if (doc.handle.tree.fullContainerField(node)) |container_field|
            try context.resolveTypeKind(doc, .{ .container_field = container_field })
        else
            @panic("Fail");

        std.testing.expectEqual(test_case.kind, actual_kind) catch |e| {
            const border: [50]u8 = @splat('-');
            std.debug.print("Node:\n{s}\n{s}\n{s}\n", .{ border, doc.handle.tree.getNodeSource(node), border });
            std.debug.print("Expected: {any}\n", .{test_case.kind});
            std.debug.print("Actual: {any}\n", .{actual_kind});
            std.debug.print("Contents:\n{s}\n{s}\n{s}\n", .{ border, test_case.contents, border });

            return e;
        };
    }
}

const ast = @import("ast.zig");
const builtin = @import("builtin");
const comments = @import("comments.zig");
const shims = @import("shims.zig");
const std = @import("std");
const testing = @import("testing.zig");
const version = @import("version.zig");
const zls = @import("zls");
const LintProblem = @import("results.zig").LintProblem;
const NodeIndexShim = shims.NodeIndexShim;
const Ast = std.zig.Ast;
