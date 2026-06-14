/// The context of all document and rule executions.
const LintContext = @This();

build_config_store: BuildConfigStore,
document_store: zls.DocumentStore,
gpa: std.mem.Allocator,
analyser: zls.Analyser,
io: std.Io,

pub fn init(
    self: *LintContext,
    config: zls.Config,
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
) !void {
    self.* = .{
        .gpa = gpa,
        .document_store = undefined, // zlinter-disable-current-line no_undefined - set below
        .analyser = undefined, // zlinter-disable-current-line no_undefined - set below
        .io = io,
        .build_config_store = .empty,
    };

    self.document_store = zls.DocumentStore{
        .io = io,
        .allocator = gpa,
        .config = .{
            .zig_exe_path = config.zig_exe_path,
            .zig_lib_dir = dir: {
                if (config.zig_lib_path) |zig_lib_path| {
                    const absolute_zig_lib_path = std.Io.Dir.cwd().realPathFileAlloc(io, zig_lib_path, arena) catch |err| {
                        std.log.err("failed to resolve zig library directory '{s}': {s}", .{ zig_lib_path, @errorName(err) });
                        break :dir null;
                    };

                    if (std.Io.Dir.openDirAbsolute(io, absolute_zig_lib_path, .{})) |zig_lib_dir| {
                        break :dir .{
                            .handle = zig_lib_dir,
                            .path = absolute_zig_lib_path,
                        };
                    } else |err| {
                        std.log.err("failed to open zig library directory '{s}': {s}", .{ absolute_zig_lib_path, @errorName(err) });
                    }
                }
                break :dir null;
            },
            .build_runner_path = config.build_runner_path,
            .builtin_path = config.builtin_path,
            .global_cache_dir = dir: {
                if (config.global_cache_path) |global_cache_path| {
                    const absolute_global_cache_path = std.Io.Dir.cwd().realPathFileAlloc(io, global_cache_path, arena) catch |err| {
                        std.log.err("failed to resolve global cache directory '{s}': {s}", .{ global_cache_path, @errorName(err) });
                        break :dir null;
                    };

                    if (std.Io.Dir.openDirAbsolute(io, absolute_global_cache_path, .{})) |global_cache_dir| {
                        break :dir .{
                            .handle = global_cache_dir,
                            .path = absolute_global_cache_path,
                        };
                    } else |err| {
                        std.log.err("failed to open global cache directory '{s}': {s}", .{ absolute_global_cache_path, @errorName(err) });
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

    self.analyser = zls.Analyser.init(
        gpa,
        arena,
        &self.document_store,
        null,
    );
}

pub fn deinit(self: *LintContext) void {
    self.document_store.deinit();
    self.analyser.deinit();
    self.build_config_store.deinit(self.gpa);
}

/// Loads and parses zig file into the document store.
///
/// Caller is responsible for calling deinit once done.
pub fn initDocument(
    self: *LintContext,
    context2: *const LintContext2,
    file_id: FileStore.FileId,
    gpa: std.mem.Allocator,
    doc: *LintDocument,
) !void {
    const abs_path = context2.file_store.fileAbsPath(file_id);
    std.debug.assert(std.fs.path.isAbsolute(abs_path));

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const size = try std.Io.Dir.cwd().realPathFile(
        self.io,
        abs_path,
        &buffer,
    );

    var mem: [std.fs.max_path_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    const uri = try zls.Uri.fromPath(
        fba.allocator(),
        buffer[0..size],
    );

    const handle = (try self.document_store.getOrLoadHandle(uri)) orelse return error.HandleError;

    const source = context2.file_store.fileSource(file_id);
    const tree = context2.file_store.fileTree(file_id);

    var src_comments = try comments.allocParse(source, gpa);
    errdefer src_comments.deinit(gpa);

    doc.* = .{
        .file_id = file_id,
        .handle = handle,
        .lineage = .empty,
        .comments = src_comments,
        .skipper = undefined, // zlinter-disable-current-line no_undefined - set below
    };
    errdefer doc.lineage.deinit(gpa);

    doc.skipper = .init(doc.comments, source, gpa);
    errdefer doc.skipper.deinit();

    {
        try doc.lineage.resize(gpa, tree.nodes.len);
        for (0..tree.nodes.len) |i| {
            doc.lineage.set(i, .{});
        }

        const QueueItem = struct {
            parent: ?Ast.Node.Index = null,
            node: Ast.Node.Index,
        };

        var queue = std.ArrayList(QueueItem).empty;
        defer queue.deinit(gpa);

        try queue.append(gpa, .{ .node = .root });

        while (queue.pop()) |item| {
            const children = try ast.nodeChildrenAlloc(
                gpa,
                tree,
                item.node,
            );

            // Ideally this is never necessary as we should only be visiting
            // each node once while walking the tree and if we're not there's
            // another bug but for now to be safe memory wise we'll ensure
            // the previous is cleaned up if needed (no-op if not needed)
            doc.lineage.get(@intFromEnum(item.node)).deinit(gpa);
            doc.lineage.set(@intFromEnum(item.node), .{
                .parent = if (item.parent) |p|
                    p
                else
                    null,
                .children = children,
            });

            for (children) |child| {
                try queue.append(gpa, .{
                    .parent = item.node,
                    .node = child,
                });
            }
        }
    }
}

/// Resolves the type of node or null if it can't be resolved.
pub fn resolveTypeOfNode(self: *LintContext, doc: *const LintDocument, node: Ast.Node.Index) !?zls.Analyser.Type {
    return self.analyser.resolveTypeOfNode(.of(node, doc.handle));
}

/// Resolves the type of a node that points to a type (e.g., return type) or
/// null if it cannot be resolved.
pub fn resolveTypeOfTypeNode(self: *LintContext, doc: *const LintDocument, node: Ast.Node.Index) !?zls.Analyser.Type {
    const resolved_type = try self.resolveTypeOfNode(doc, node) orelse return null;
    const instance_type = if (resolved_type.isMetaType()) resolved_type else try resolved_type.instanceTypeVal(&self.analyser) orelse resolved_type;

    return ast.resolveDeclLiteralResultTypeSafe(instance_type);
}

// TODO: Write tests and clean this up as they're not really all needed
pub const TypeKind = @import("DeclStore.zig").Type;

// TODO: This has gotten out of hand and really needs a revamp.... patching
// for now to get things happy with latest changes to master but needs love
// as not sustainable....
/// Resolves a given declaration or container field by looking at the type
/// node (if any) and then the value node (if any) to resolve the type.
///
/// This will return null if the kind could not be resolved, usually indicating
/// that the input was unexpected / invalid.
pub fn resolveTypeKind(self: *LintContext, doc: *const LintDocument, input: union(enum) {
    var_decl: Ast.full.VarDecl,
    container_field: Ast.full.ContainerField,
    type_node: Ast.Node.Index,
}) !?TypeKind {
    const is_direct_type_node = switch (input) {
        .type_node => true,
        else => false,
    };
    const maybe_type_node: ?Ast.Node.Index = switch (input) {
        .var_decl => |var_decl| var_decl.ast.type_node.unwrap(),
        .container_field => |container_field| container_field.ast.type_expr.unwrap(),
        .type_node => |node| node,
    };
    const maybe_value_node: ?Ast.Node.Index = switch (input) {
        .var_decl => |var_decl| var_decl.ast.init_node.unwrap(),
        .container_field => |container_field| container_field.ast.value_expr.unwrap(),
        .type_node => null,
    };

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    var fn_proto_buffer: [1]Ast.Node.Index = undefined;

    const tree = doc.handle.tree;

    // First we try looking for a <type> node in the declaration. e.g.,
    // `const var_name: <type> = ....`
    if (maybe_type_node) |type_node| {
        const node = ast.unwrapNode(tree, type_node, .{});

        if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
            if (fn_proto.ast.return_type.unwrap()) |return_node| {
                const return_unwrapped = ast.unwrapNode(tree, return_node, .{});

                // If it's a function proto, then return whether or not the function returns `type`
                const is_type_identifier = ast.isIdentiferKind(tree, return_unwrapped, .type);
                return if (is_type_identifier) .fn_returns_type else .@"fn";
            } else {
                return .@"fn";
            }
        } else if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
            // If's it's a container declaration (e.g., struct {}) then resolve what type of container
            switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
                // Instance of namespace should be impossible but to be safe
                // we will just return null to say we couldn't resolve the kind
                .keyword_struct => return if (ast.isContainerNamespace(tree, container_decl)) null else .struct_instance,
                .keyword_union => return .union_instance,
                .keyword_opaque => return .opaque_instance,
                .keyword_enum => return .enum_instance,
                inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
            }
        } else if ((tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.getNodeSource(node), "type")) or
            ast.isIdentiferKind(tree, node, .type))
        {
            return .type;
        } else if (is_direct_type_node and tree.nodeTag(node) == .identifier) {
            const identifier_token = tree.firstToken(node);
            const source_index = tree.tokens.items(.start)[identifier_token];
            if (try self.analyser.lookupSymbolGlobal(
                doc.handle,
                tree.tokenSlice(identifier_token),
                source_index,
            )) |decl_with_handle| {
                if (decl_with_handle.decl == .ast_node) {
                    const decl_node = decl_with_handle.decl.ast_node;
                    if (decl_with_handle.handle.tree.fullVarDecl(decl_node)) |var_decl| {
                        if (std.mem.eql(u8, decl_with_handle.handle.uri.raw, doc.handle.uri.raw)) {
                            return try self.resolveTypeKind(doc, .{ .var_decl = var_decl });
                        }
                    }

                    var fn_decl_buffer: [1]Ast.Node.Index = undefined;
                    if (decl_with_handle.handle.tree.fullFnProto(&fn_decl_buffer, decl_node)) |fn_proto| {
                        if (fn_proto.ast.return_type.unwrap()) |return_node| {
                            const return_unwrapped = ast.unwrapNode(decl_with_handle.handle.tree, return_node, .{});
                            return if (ast.isIdentiferKind(decl_with_handle.handle.tree, return_unwrapped, .type))
                                .fn_returns_type
                            else
                                .@"fn";
                        }
                        return .@"fn";
                    }
                }
            }
        } else if (try self.resolveTypeOfNode(doc, node)) |type_node_type| {
            if (!type_node_type.is_type_val) {
                return if (type_node_type.isTypeFunc())
                    .fn_returns_type
                else if (type_node_type.isFunc())
                    .@"fn"
                else
                    .other;
            }

            const decl = ast.resolveDeclLiteralResultTypeSafe(type_node_type);

            return if (decl.isUnionType())
                .union_instance
            else if (decl.isEnumType())
                .enum_instance
            else if (decl.isStructType(&self.analyser))
                .struct_instance
            else if (decl.isTypeFunc())
                .fn_returns_type
            else if (decl.isFunc())
                .@"fn"
            else if (isTypeUnknown(type_node_type))
                .other
            else
                .other;
        }

        if (maybe_value_node == null) {
            return if ((tree.nodeTag(node) == .identifier and std.mem.eql(u8, tree.getNodeSource(node), "type")) or
                ast.isIdentiferKind(tree, node, .type))
                .type
            else
                .other;
        }
    }

    // Then we look at the initialisation <value> if a type couldn't be used
    // from then declaration. e.g., `const var_name = <value>`
    if (maybe_value_node) |value_node| {
        const node = ast.unwrapNode(tree, value_node, .{
            .unwrap_optional_unwrap = false,
        });

        if (tree.nodeTag(node) == .identifier) {
            const identifier_token = tree.firstToken(node);
            const source_index = tree.tokens.items(.start)[identifier_token];
            if (try self.analyser.lookupSymbolGlobal(
                doc.handle,
                tree.tokenSlice(identifier_token),
                source_index,
            )) |decl_with_handle| {
                if (decl_with_handle.decl == .ast_node) {
                    const decl_node = decl_with_handle.decl.ast_node;
                    if (decl_with_handle.handle.tree.fullVarDecl(decl_node)) |var_decl| {
                        if (std.mem.eql(u8, decl_with_handle.handle.uri.raw, doc.handle.uri.raw)) {
                            return try self.resolveTypeKind(doc, .{ .var_decl = var_decl });
                        }
                    }
                }
            }
        }
        if (tree.nodeTag(node) == .field_access) {
            const lhs = tree.nodeData(node).node_and_token.@"0";
            if (tree.nodeTag(lhs) == .identifier) {
                lhs_lookup: {
                    const lhs_token = tree.firstToken(lhs);
                    const lhs_source_index = tree.tokens.items(.start)[lhs_token];
                    const decl_with_handle = (try self.analyser.lookupSymbolGlobal(
                        doc.handle,
                        tree.tokenSlice(lhs_token),
                        lhs_source_index,
                    )) orelse break :lhs_lookup;
                    if (decl_with_handle.decl != .ast_node) break :lhs_lookup;

                    const decl_node = decl_with_handle.decl.ast_node;
                    const var_decl = decl_with_handle.handle.tree.fullVarDecl(decl_node) orelse break :lhs_lookup;
                    const init_node = var_decl.ast.init_node.unwrap() orelse break :lhs_lookup;
                    const container_decl = decl_with_handle.handle.tree.fullContainerDecl(&container_decl_buffer, init_node) orelse break :lhs_lookup;
                    const container_token_tag = decl_with_handle.handle.tree.tokens.items(.tag)[container_decl.ast.main_token];
                    if (container_token_tag == .keyword_enum) return .enum_instance;
                }
            }

            var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_allocator.deinit();
            const arena = arena_allocator.allocator();

            if (try self.resolveDecl(doc.handle, node, arena)) |decl_with_handle| {
                if (decl_with_handle.decl == .ast_node) {
                    const decl_node = decl_with_handle.decl.ast_node;
                    if (decl_with_handle.handle.tree.nodeTag(decl_node) == .enum_literal) {
                        return .enum_instance;
                    }
                }
            }
        }

        var struct_init_buffer: [2]Ast.Node.Index = undefined;
        var fn_proto_from_init_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
            if (struct_init.ast.type_expr.unwrap()) |init_type_expr| {
                const init_type = ast.unwrapNode(tree, init_type_expr, .{});
                if (tree.fullFnProto(&fn_proto_from_init_buffer, init_type)) |fn_proto| {
                    if (fn_proto.ast.return_type.unwrap()) |return_node| {
                        const return_unwrapped = ast.unwrapNode(tree, return_node, .{});
                        return if (ast.isIdentiferKind(tree, return_unwrapped, .type))
                            .fn_returns_type
                        else
                            .@"fn";
                    }
                    return .@"fn";
                }

                if (tree.nodeTag(init_type) == .identifier) {
                    const type_name_token = tree.firstToken(init_type);
                    const source_index = tree.tokens.items(.start)[type_name_token];
                    if (try self.analyser.lookupSymbolGlobal(
                        doc.handle,
                        tree.tokenSlice(type_name_token),
                        source_index,
                    )) |decl_with_handle| {
                        if (decl_with_handle.decl == .ast_node) {
                            const decl_node = decl_with_handle.decl.ast_node;
                            if (decl_with_handle.handle.tree.fullContainerDecl(&container_decl_buffer, decl_node)) |container_decl| {
                                if (ast.isContainerNamespace(decl_with_handle.handle.tree, container_decl)) return null;
                            }
                            if (decl_with_handle.handle.tree.fullVarDecl(decl_node)) |var_decl| {
                                if (var_decl.ast.init_node.unwrap()) |init_node| {
                                    if (decl_with_handle.handle.tree.fullContainerDecl(&container_decl_buffer, init_node)) |container_decl| {
                                        const container_token_tag = decl_with_handle.handle.tree.tokens.items(.tag)[container_decl.ast.main_token];
                                        switch (container_token_tag) {
                                            .keyword_struct => {
                                                if (ast.isContainerNamespace(decl_with_handle.handle.tree, container_decl)) return null;
                                                return .struct_instance;
                                            },
                                            .keyword_union => return .union_instance,
                                            .keyword_enum => return .enum_instance,
                                            .keyword_opaque => return .opaque_instance,
                                            else => {},
                                        }
                                    }
                                }
                            }
                        }
                    } else return null;
                }
            }
        }

        if (tree.nodeTag(node) == .address_of) {
            const target_node = tree.nodeData(node).node;

            var fn_proto_buffer_addr_of: [1]Ast.Node.Index = undefined;
            const target_unwrapped = ast.unwrapNode(tree, target_node, .{
                .unwrap_optional_unwrap = false,
            });
            if (tree.fullFnProto(&fn_proto_buffer_addr_of, target_unwrapped)) |fn_proto| {
                if (fn_proto.ast.return_type.unwrap()) |return_node| {
                    const return_unwrapped = ast.unwrapNode(tree, return_node, .{});
                    return if (ast.isIdentiferKind(tree, return_unwrapped, .type))
                        .fn_returns_type
                    else
                        .@"fn";
                }
                return .@"fn";
            }

            var arena_allocator = std.heap.ArenaAllocator.init(self.gpa);
            defer arena_allocator.deinit();
            const arena = arena_allocator.allocator();
            if (try self.resolveDecl(doc.handle, target_node, arena)) |decl_with_handle| {
                if (decl_with_handle.decl == .ast_node) {
                    const decl_node = decl_with_handle.decl.ast_node;
                    if (decl_with_handle.handle.tree.fullFnProto(&fn_proto_buffer_addr_of, decl_node)) |fn_proto| {
                        if (fn_proto.ast.return_type.unwrap()) |return_node| {
                            const return_unwrapped = ast.unwrapNode(decl_with_handle.handle.tree, return_node, .{});
                            return if (ast.isIdentiferKind(decl_with_handle.handle.tree, return_unwrapped, .type))
                                .fn_returns_type
                            else
                                .@"fn";
                        }
                        return .@"fn";
                    }
                }
            }
        }

        // LIMITATION: All builtin calls to type of and type will return
        // `type` without any resolution.
        switch (tree.nodeTag(node)) {
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => inline for (&.{ "@Type", "@TypeOf" }) |builtin_name| {
                if (std.mem.eql(u8, builtin_name, tree.tokenSlice(tree.nodeMainToken(node)))) {
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
                .keyword_struct => if (ast.isContainerNamespace(tree, container_decl)) .namespace_type else .struct_type,
                .keyword_union => .union_type,
                .keyword_opaque => .opaque_type,
                .keyword_enum => .enum_type,
                inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
            };
        } else if (try self.resolveTypeOfNode(doc, node)) |init_node_type| {
            if (!init_node_type.is_type_val) {
                return if (init_node_type.isTypeFunc())
                    .fn_returns_type
                else if (init_node_type.isFunc())
                    .@"fn"
                else
                    .other;
            }

            const decl = ast.resolveDeclLiteralResultTypeSafe(init_node_type);

            const is_error_container =
                if (std.meta.hasMethod(@TypeOf(decl), "isErrorSetType"))
                    decl.isErrorSetType(&self.analyser)
                else switch (decl.data) {
                    .container => |container| result: {
                        const container_node, const container_tree = .{ container.scope_handle.toNode(), container.scope_handle.handle.tree };

                        if (container_node != .root) {
                            switch (container_tree.nodeTag(container_node)) {
                                .error_set_decl => break :result true,
                                else => {},
                            }
                        }
                        break :result false;
                    },
                    else => false,
                };

            const is_type_val = init_node_type.is_type_val;
            if (!is_type_val and decl.data == .container) {
                const container_node = decl.data.container.scope_handle.toNode();
                if (container_node != .root) {
                    const container_tree = decl.data.container.scope_handle.handle.tree;
                    const container_token = container_tree.nodeMainToken(container_node);
                    switch (container_tree.tokenTag(container_token)) {
                        .keyword_struct => {
                            var buf: [2]Ast.Node.Index = undefined;
                            if (container_tree.fullContainerDecl(&buf, container_node)) |container_decl| {
                                if (ast.isContainerNamespace(container_tree, container_decl)) return null;
                            }
                            return .struct_instance;
                        },
                        .keyword_union => return .union_instance,
                        .keyword_opaque => return .opaque_instance,
                        .keyword_enum => return .enum_instance,
                        else => {},
                    }
                }
            }

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
            else if (decl.isStructType(&self.analyser))
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

        var context: LintContext = undefined;
        try context.init(.{}, std.testing.io, std.testing.allocator, arena.allocator());
        defer context.deinit();

        var context2 = testing.initFakeContext2(
            std.testing.allocator,
            arena.allocator(),
            std.testing.io,
        );
        defer context2.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            &context2,
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

const ast = @import("../ast.zig");
const builtin = @import("builtin");
const comments = @import("../comments.zig");
const std = @import("std");
const testing = @import("../testing.zig");
const zls = @import("zls");
const BuildConfigStore = @import("BuildConfigStore.zig");
const FileStore = @import("FileStore.zig");
const LintContext2 = @import("LintContext2.zig");
const LintDocument = @import("LintDocument.zig");
const Ast = std.zig.Ast;

test {
    std.testing.refAllDecls(@This());
}
