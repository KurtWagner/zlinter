const DeclStore = @This();

decls: std.MultiArrayList(Decl) = .empty,
scopes: std.MultiArrayList(Scope) = .empty,
decl_id_by_ast_node: std.AutoHashMapUnmanaged(DeclAstNodeKey, DeclId) = .empty,
decl_ids_by_file: std.AutoHashMapUnmanaged(FileStore.FileId, std.ArrayList(DeclId)) = .empty,
scope_id_by_owner_node: std.AutoHashMapUnmanaged(ScopeOwnerKey, ScopeId) = .empty,
scope_id_by_owner_decl: std.AutoHashMapUnmanaged(DeclId, ScopeId) = .empty,
import_member_by_context: std.HashMapUnmanaged(
    ImportMemberKey,
    ?DeclId,
    ImportMemberKey.context,
    std.hash_map.default_max_load_percentage,
) = .empty,

/// Lives for the full linter invocation.
runtime: *const LintRuntime,
pub fn init(runtime: *const LintRuntime) DeclStore {
    return .{
        .runtime = runtime,
    };
}

pub const DeclKind = enum {
    /// e.g., `const value = 1`, `fn run() void`, or a function parameter.
    declaration,
    /// e.g., `struct { value: u32 }` or `enum { value }`.
    field,
    /// e.g., `label: { ... }`.
    label,
};

const Decl = struct {
    /// If unset, it's the root declaration.
    name_token: ?std.zig.Ast.TokenIndex,
    /// Token-only declarations, such as function parameters, do not have an
    /// owning AST node.
    ast_node: ?std.zig.Ast.Node.Index,
    type_node: ?std.zig.Ast.Node.Index,
    scope_id: ?ScopeId,
    file_id: FileStore.FileId,
    kind: DeclKind,
    resolved_type: ?TypeStore.TypeId = null,
    resolved_type_target: ?TypeTarget = null,
};

const Scope = struct {
    file_id: FileStore.FileId,
    owner_node: std.zig.Ast.Node.Index,
    parent_scope_id: ?ScopeId,
    owner_decl_id: ?DeclId,
    decl_id_by_name: std.StringHashMapUnmanaged(DeclId),
};

pub const ScopeId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) ScopeId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: ScopeId) usize {
        return @intFromEnum(self);
    }
};

pub const DeclId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) DeclId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: DeclId) usize {
        return @intFromEnum(self);
    }
};

pub const TypeTarget = union(enum) {
    decl: DeclId,
    container: struct {
        file_id: FileStore.FileId,
        node: std.zig.Ast.Node.Index,
    },
};

const DeclAstNodeKey = enum(u64) {
    _,

    fn init(file_id: FileStore.FileId, ast_node: std.zig.Ast.Node.Index) DeclAstNodeKey {
        return @enumFromInt(packFileNodeKey(file_id, ast_node));
    }
};

const ScopeOwnerKey = enum(u64) {
    _,

    fn init(file_id: FileStore.FileId, owner_node: std.zig.Ast.Node.Index) ScopeOwnerKey {
        return @enumFromInt(packFileNodeKey(file_id, owner_node));
    }
};

const ImportMemberKey = struct {
    parent_file_id: FileStore.FileId,
    init_node: std.zig.Ast.Node.Index,
    module_id: ?ModuleStore.ModuleId,
    root_file_id: ?FileStore.FileId,
    member_name: []const u8,

    fn init(
        ctx: ResolveContext,
        parent_file_id: FileStore.FileId,
        init_node: std.zig.Ast.Node.Index,
        member_name: []const u8,
    ) ImportMemberKey {
        return .{
            .parent_file_id = parent_file_id,
            .init_node = init_node,
            .module_id = ctx.module_id,
            .root_file_id = ctx.root_file_id,
            .member_name = member_name,
        };
    }

    const context = struct {
        pub fn hash(_: context, key: ImportMemberKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHash(&hasher, key.parent_file_id);
            std.hash.autoHash(&hasher, key.init_node);
            hashOptionalModuleId(&hasher, key.module_id);
            hashOptionalFileId(&hasher, key.root_file_id);
            hasher.update(key.member_name);
            return hasher.final();
        }

        pub fn eql(_: context, a: ImportMemberKey, b: ImportMemberKey) bool {
            return a.parent_file_id == b.parent_file_id and
                a.init_node == b.init_node and
                a.module_id == b.module_id and
                a.root_file_id == b.root_file_id and
                std.mem.eql(u8, a.member_name, b.member_name);
        }

        fn hashOptionalModuleId(
            hasher: *std.hash.Wyhash,
            maybe_module_id: ?ModuleStore.ModuleId,
        ) void {
            // zlinter-disable no_literal_args
            if (maybe_module_id) |module_id| {
                std.hash.autoHash(hasher, true);
                std.hash.autoHash(hasher, module_id);
            } else {
                std.hash.autoHash(hasher, false);
            }
            // zlinter-enable no_literal_args
        }

        fn hashOptionalFileId(
            hasher: *std.hash.Wyhash,
            maybe_file_id: ?FileStore.FileId,
        ) void {
            // zlinter-disable no_literal_args
            if (maybe_file_id) |file_id| {
                std.hash.autoHash(hasher, true);
                std.hash.autoHash(hasher, file_id);
            } else {
                std.hash.autoHash(hasher, false);
            }
            // zlinter-enable no_literal_args
        }
    };
};

fn packFileNodeKey(
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) u64 {
    return (@as(u64, @intFromEnum(file_id)) << 32) |
        @as(u64, @intFromEnum(node));
}

comptime {
    std.debug.assert(@bitSizeOf(FileStore.FileId) == 32);
    std.debug.assert(@bitSizeOf(std.zig.Ast.Node.Index) == 32);
}

/// Stores declarations and lexical scopes for a parsed file.
pub fn store(
    self: *DeclStore,
    file_id: FileStore.FileId,
    file_store: *FileStore,
) DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.store");
    defer zone.end();

    if (self.decl_id_by_ast_node.get(.init(file_id, .root))) |root_decl_id|
        return root_decl_id;

    const tree = file_store.fileTree(file_id);

    const root_decl_id = self.appendDecl(
        file_id,
        null,
        .root,
        null,
        null,
        .declaration,
    );

    const root_scope_id = self.appendScope(
        file_id,
        .root,
        null,
        root_decl_id,
    );

    self.walkContainer(
        tree,
        file_id,
        root_scope_id,
        .root,
    );

    return root_decl_id;
}

pub fn resolveFileTypes(
    self: *DeclStore,
    file_id: FileStore.FileId,
    ctx: ResolveContext,
    type_store: *TypeStore,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveFileTypes");
    defer zone.end();

    _ = self.store(file_id, ctx.file_store);

    var it = self.fileDeclIterator(file_id);
    while (it.next()) |decl_id| {
        const decl_ctx = ctx.withParent(self.declFileId(decl_id));
        const type_id = if (self.resolveDeclType(
            decl_ctx,
            decl_id,
        )) |summary|
            type_store.store(summary)
        else
            null;
        const type_target = self.resolveDeclTypeTargetForValue(
            decl_ctx,
            decl_id,
        );

        self.decls.items(.resolved_type)[decl_id.toIndex()] = type_id;
        self.decls.items(.resolved_type_target)[decl_id.toIndex()] = type_target;
    }
}

/// Debug helper that prints all declarations recorded for a file.
pub fn debugPrintFileDecls(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    file_store: *const FileStore,
    type_store: *const TypeStore,
) void {
    const tree = file_store.fileTree(file_id);

    var it = self.fileDeclIterator(file_id);
    while (it.next()) |decl_id| {
        const name = if (self.declNameToken(decl_id)) |token|
            tree.tokenSlice(token)
        else
            "<root>";
        std.debug.print(" - {s} ({s}, ", .{
            name,
            @tagName(self.declKind(decl_id)),
        });
        if (self.declResolvedType(decl_id)) |type_id| {
            TypeStore.debugPrintSummary(type_store.summary(type_id));
        } else if (self.declKind(decl_id) == .label) {
            std.debug.print("n/a", .{});
        } else if (self.declAstNode(decl_id) == null and self.declTypeNode(decl_id) == null) {
            std.debug.print("untyped", .{});
        } else {
            std.debug.print("unresolved", .{});
        }
        std.debug.print(")\n", .{});
    }
}

pub fn declFileId(self: *const DeclStore, id: DeclId) FileStore.FileId {
    return self.decls.items(.file_id)[id.toIndex()];
}

pub fn declScopeId(self: *const DeclStore, id: DeclId) ?ScopeId {
    return self.decls.items(.scope_id)[id.toIndex()];
}

pub fn declAstNode(self: *const DeclStore, id: DeclId) ?std.zig.Ast.Node.Index {
    return self.decls.items(.ast_node)[id.toIndex()];
}

pub fn declTypeNode(self: *const DeclStore, id: DeclId) ?std.zig.Ast.Node.Index {
    return self.decls.items(.type_node)[id.toIndex()];
}

pub fn declNameToken(self: *const DeclStore, id: DeclId) ?std.zig.Ast.TokenIndex {
    return self.decls.items(.name_token)[id.toIndex()];
}

pub fn declKind(self: *const DeclStore, id: DeclId) DeclKind {
    return self.decls.items(.kind)[id.toIndex()];
}

pub fn declResolvedType(self: *const DeclStore, id: DeclId) ?TypeStore.TypeId {
    return self.decls.items(.resolved_type)[id.toIndex()];
}

pub fn declResolvedTypeTarget(self: *const DeclStore, id: DeclId) ?TypeTarget {
    return self.decls.items(.resolved_type_target)[id.toIndex()];
}

pub fn declResolvedTypeDecl(self: *const DeclStore, id: DeclId) ?DeclId {
    return switch (self.declResolvedTypeTarget(id) orelse return null) {
        .decl => |decl_id| decl_id,
        .container => null,
    };
}

/// Resolves an expression node to the declaration it names.
///
/// `context_decl_id` supplies the lexical scope to start lookup from. For
/// example, resolving an identifier inside a function should search that
/// function's local scope before walking out to the file root.
pub fn resolveDeclByNode(
    self: *DeclStore,
    ctx: ResolveContext,
    context_decl_id: DeclId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveNodeDecl");
    defer zone.end();

    const file_id = self.declFileId(context_decl_id);
    const tree = ctx.file_store.fileTree(file_id);
    const unwrapped = ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    if (isThisBuiltinCall(tree, unwrapped)) {
        return self.rootDecl(file_id);
    }

    const scope_id = self.declScopeId(context_decl_id) orelse return null;
    return self.resolveExprDeclFromScope(
        ctx.withParent(file_id),
        file_id,
        scope_id,
        node,
        context_decl_id,
    );
}

pub fn resolveNodeDeclWithRoot(
    self: *DeclStore,
    ctx: ResolveContext,
    context_decl_id: DeclId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    return self.resolveDeclByNode(ctx, context_decl_id, node);
}

/// Resolves an expression node to the declaration it names from a lexical scope.
pub fn resolveDeclByNodeFromScope(
    self: *DeclStore,
    ctx: ResolveContext,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveNodeDeclFromScope");
    defer zone.end();

    const tree = ctx.file_store.fileTree(file_id);
    const unwrapped = ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    if (isThisBuiltinCall(tree, unwrapped))
        return self.rootDecl(file_id);

    return self.resolveExprDeclFromScope(
        ctx.withParent(file_id),
        file_id,
        scope_id,
        node,
        null,
    );
}

pub fn resolveNodeDeclFromScope(
    self: *DeclStore,
    ctx: ResolveContext,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    return self.resolveDeclByNodeFromScope(ctx, file_id, scope_id, node);
}

/// Returns the stored declaration represented by this AST node, if any.
///
/// This is a direct node-to-declaration lookup, it does not resolve identifier
/// references or field accesses.
pub fn declIdByNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    return self.declByAstNode(file_id, node);
}

pub fn declByNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    return self.declIdByNode(file_id, node);
}

pub fn rootDecl(
    self: *const DeclStore,
    file_id: FileStore.FileId,
) ?DeclId {
    return self.fileRootDecl(file_id);
}

/// Returns the lexical scope owned by an AST node, if one was recorded.
pub fn scopeIdByNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?ScopeId {
    const zone = tracy.traceNamed(@src(), "DeclStore.scopeIdByNode");
    defer zone.end();

    return self.scope_id_by_owner_node.get(.init(file_id, node));
}

pub fn scopeByNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?ScopeId {
    return self.scopeIdByNode(file_id, node);
}

/// Returns the declaration that should be treated as the container identity.
///
/// Most declarations resolve to themselves. Aliases such as
/// `const Self = @This();` resolve to the file root declaration so callers can
/// treat `Self.member` the same as `@This().member`.
pub fn resolvedContainerDecl(
    self: *const DeclStore,
    file_store: *const FileStore,
    decl_id: DeclId,
) ?DeclId {
    const file_id = self.declFileId(decl_id);
    const node = self.declAstNode(decl_id) orelse return null;

    if (node == .root) return decl_id;

    const tree = file_store.fileTree(file_id);
    const var_decl = tree.fullVarDecl(node) orelse return decl_id;
    const init_node = var_decl.ast.init_node.unwrap() orelse return decl_id;
    const init_expr = ast.unwrapNode(tree, init_node, .{
        .unwrap_optional_unwrap = false,
    });

    if (isThisBuiltinCall(tree, init_expr)) {
        return self.rootDecl(file_id);
    }

    return decl_id;
}

/// Resolves the declaration named by a declaration's type expression.
pub fn resolveDeclTypeDecl(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveDeclTypeDecl");
    defer zone.end();

    const type_node = self.declTypeNode(decl_id) orelse return null;
    return self.resolveTypeExprDecl(
        ctx,
        decl_id,
        type_node,
    );
}

/// Looks up a declaration by name directly within a scope.
fn scopeDecl(self: *const DeclStore, scope_id: ScopeId, name: []const u8) ?DeclId {
    return self.scopes.items(.decl_id_by_name)[scope_id.toIndex()].get(name);
}

/// Computes the value/type summary for a declaration in a given root context.
///
/// The caller decides whether and how to cache it because results can differ
/// between modules that resolve imports differently.
pub fn resolveDeclType(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    const node = self.declAstNode(decl_id) orelse {
        const type_node = self.declTypeNode(decl_id) orelse return null;
        return TypeStore.summarizeTypeNode(tree, type_node);
    };

    if (node == .root) return TypeStore.summarizeRoot();

    if (tree.fullVarDecl(node)) |var_decl| {
        return self.resolveVarDeclType(
            ctx,
            decl_id,
            var_decl,
        );
    }

    if (tree.fullContainerField(node)) |field| {
        return self.resolveContainerFieldType(
            ctx,
            decl_id,
            field,
        );
    }

    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return TypeStore.summarizeFnProto(tree, fn_proto, .summary);
    }

    return null;
}

fn resolveVarDeclType(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    var_decl: std.zig.Ast.full.VarDecl,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    if (var_decl.ast.type_node.unwrap()) |type_node| {
        return valueSummaryFromTypeAnnotation(tree, type_node) orelse
            explicitTypeAnnotationSummary(tree, type_node);
    }
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (self.resolveCallReturnType(
        ctx,
        decl_id,
        init_node,
    )) |summary| return summary;
    if (self.resolveValueAliasType(
        ctx,
        decl_id,
        init_node,
    )) |summary| return summary;
    if (self.resolveInstanceValueType(
        ctx,
        decl_id,
        init_node,
    )) |summary| return summary;
    return TypeStore.summarizeValueNode(tree, init_node);
}

fn resolveContainerFieldType(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    field: std.zig.Ast.full.ContainerField,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    if (field.ast.type_expr.unwrap()) |type_node| {
        return valueSummaryFromTypeAnnotation(tree, type_node) orelse
            explicitTypeAnnotationSummary(tree, type_node);
    }
    const value_node = field.ast.value_expr.unwrap() orelse return null;
    if (self.resolveCallReturnType(
        ctx,
        decl_id,
        value_node,
    )) |summary| return summary;
    if (self.resolveValueAliasType(
        ctx,
        decl_id,
        value_node,
    )) |summary| return summary;
    if (self.resolveInstanceValueType(
        ctx,
        decl_id,
        value_node,
    )) |summary| return summary;
    return TypeStore.summarizeValueNode(tree, value_node);
}

fn valueSummaryFromTypeAnnotation(
    tree: std.zig.Ast,
    type_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const type_summary = TypeStore.summarizeTypeNode(tree, type_node);
    return switch (type_summary.typeValueKind() orelse return null) {
        .error_set => .{ .instance = .{ .kind = .error_set } },
        else => null,
    };
}

/// Explicit annotations are known type syntax even when `TypeStore` cannot
/// resolve their underlying category. Treat those annotations as `.other`
/// instead of `.unknown` so callers can distinguish "not modeled" from
/// "resolution failed".
fn explicitTypeAnnotationSummary(
    tree: std.zig.Ast,
    type_node: std.zig.Ast.Node.Index,
) TypeStore.TypeSummary {
    const summary = TypeStore.summarizeTypeNode(tree, type_node);
    return switch (summary) {
        .unknown => .other,
        else => summary,
    };
}

fn resolveValueAliasType(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    const target_node = if (tree.nodeTag(node) == .address_of)
        tree.nodeData(node).node
    else
        node;

    const target_decl_id = self.resolveExprDecl(
        ctx,
        decl_id,
        target_node,
    ) orelse return null;
    if (target_decl_id == decl_id) return null;

    const summary = self.resolveDeclType(
        ctx,
        target_decl_id,
    ) orelse return null;

    return switch (summary) {
        .unknown, .other, .primitive => null,
        else => summary,
    };
}

fn resolveInstanceValueType(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    var struct_init_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
        const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
        const type_summary = self.resolveTypeExprValueSummary(
            ctx,
            decl_id,
            type_expr,
        ) orelse return null;

        return instanceSummaryFromTypeSummary(type_summary);
    }

    if (tree.nodeTag(node) == .field_access) {
        const target_node, _ = tree.nodeData(node).node_and_token;
        if (tree.nodeTag(target_node) == .identifier and
            std.mem.eql(u8, tree.getNodeSource(target_node), "error"))
        {
            return .{ .instance = .{ .kind = .error_set } };
        }

        const target_summary = self.resolveTypeExprValueSummary(
            ctx,
            decl_id,
            target_node,
        ) orelse return null;

        if (target_summary.typeValueKind() == .@"enum") {
            return .{ .instance = .{ .kind = .@"enum" } };
        }
    }

    return null;
}

fn resolveTypeExprValueSummary(
    self: *DeclStore,
    ctx: ResolveContext,
    context_decl_id: DeclId,
    type_expr: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(context_decl_id));
    const summary = TypeStore.summarizeValueNode(tree, type_expr) orelse .unknown;
    switch (summary) {
        .unknown => {},
        else => return summary,
    }

    const target = self.resolveTypeExprTarget(
        ctx,
        context_decl_id,
        type_expr,
    ) orelse return null;

    return self.summarizeTypeTargetValue(
        ctx,
        target,
    );
}

fn instanceSummaryFromTypeSummary(summary: TypeStore.TypeSummary) ?TypeStore.TypeSummary {
    return switch (summary.typeValueKind() orelse return null) {
        .@"struct" => .{ .instance = .{ .kind = .@"struct" } },
        // Namespace containers are still zero-field structs at the value level,
        // so struct init syntax on them should behave like a struct instance.
        .namespace => .{ .instance = .{ .kind = .@"struct" } },
        .@"union" => .{ .instance = .{ .kind = .@"union" } },
        .@"enum" => .{ .instance = .{ .kind = .@"enum" } },
        .@"opaque" => .{ .instance = .{ .kind = .@"opaque" } },
        .error_set => .{ .instance = .{ .kind = .error_set } },
        else => null,
    };
}

fn resolveCallReturnType(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;
    const callee_decl_id = self.resolveExprDecl(
        ctx,
        decl_id,
        call.ast.fn_expr,
    ) orelse return null;

    const return_type = self.resolveFunctionDeclReturnType(ctx.file_store, callee_decl_id) orelse return null;
    if (return_type.coarseType() != .type) return return_type;

    const target = self.resolveTypeFactoryResultTarget(
        ctx,
        callee_decl_id,
    ) orelse return return_type;

    return self.summarizeTypeTargetValue(
        ctx,
        target,
    ) orelse return_type;
}

fn summarizeTypeTargetValue(
    self: *DeclStore,
    ctx: ResolveContext,
    target: TypeTarget,
) ?TypeStore.TypeSummary {
    return switch (target) {
        .decl => |decl_id| self.resolveDeclType(
            ctx,
            decl_id,
        ),
        .container => |container| blk: {
            const tree = ctx.file_store.fileTree(container.file_id);
            if (@intFromEnum(container.node) >= tree.nodes.len) break :blk null;
            break :blk TypeStore.summarizeValueNode(
                tree,
                container.node,
            );
        },
    };
}

fn resolveExprDecl(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    expr_node: std.zig.Ast.Node.Index,
) ?DeclId {
    const file_id = self.declFileId(decl_id);
    const scope_id = self.declScopeId(decl_id) orelse return null;
    return self.resolveExprDeclFromScope(
        ctx.withParent(file_id),
        file_id,
        scope_id,
        expr_node,
        decl_id,
    );
}

fn resolveExprDeclFromScope(
    self: *DeclStore,
    ctx: ResolveContext,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    expr_node: std.zig.Ast.Node.Index,
    skip_decl_id: ?DeclId,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveExprDeclFromScope");
    defer zone.end();

    const tree = ctx.file_store.fileTree(file_id);
    const node = ast.unwrapNode(tree, expr_node, .{
        .unwrap_optional_unwrap = false,
    });

    switch (tree.nodeTag(node)) {
        .identifier => return self.lookupVisibleDecl(
            scope_id,
            tree.getNodeSource(node),
            skip_decl_id,
        ),
        .field_access => {
            const target_node, const member_token = tree.nodeData(node).node_and_token;
            if (self.resolveImportMember(
                ctx.withParent(file_id),
                file_id,
                target_node,
                tree.tokenSlice(member_token),
            )) |decl_id| return decl_id;

            const target_decl_id = self.resolveExprDeclFromScope(
                ctx.withParent(file_id),
                file_id,
                scope_id,
                target_node,
                skip_decl_id,
            ) orelse return null;

            return self.resolveMemberDecl(
                ctx.withParent(file_id),
                target_decl_id,
                tree.tokenSlice(member_token),
            );
        },
        else => return null,
    }
}

fn resolveFunctionDeclReturnType(
    self: *const DeclStore,
    file_store: *FileStore,
    decl_id: DeclId,
) ?TypeStore.TypeSummary {
    const node = self.declAstNode(decl_id) orelse return null;

    const tree = file_store.fileTree(self.declFileId(decl_id));
    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(
        &fn_proto_buffer,
        node,
    ) orelse return null;

    return TypeStore.summarizeFnReturnType(tree, fn_proto);
}

pub fn resolveMemberDecl(
    self: *DeclStore,
    ctx: ResolveContext,
    parent_decl_id: DeclId,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveMemberDecl");
    defer zone.end();

    if (self.resolveMemberDeclFromType(
        ctx,
        parent_decl_id,
        member_name,
    )) |decl_id| {
        return decl_id;
    }

    const node = self.declAstNode(parent_decl_id) orelse return null;

    const parent_file_id = self.declFileId(parent_decl_id);
    const tree = ctx.file_store.fileTree(parent_file_id);
    if (node == .root) return self.resolveFileRootMember(
        ctx.file_store,
        parent_file_id,
        member_name,
    );

    const var_decl = tree.fullVarDecl(node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (!nodeBelongsToTree(tree, init_node)) return null;

    if (self.resolveImportMember(
        ctx.withParent(parent_file_id),
        parent_file_id,
        init_node,
        member_name,
    )) |decl_id| {
        return decl_id;
    }

    if (self.resolveExprDecl(
        ctx,
        parent_decl_id,
        init_node,
    )) |target_decl_id| {
        if (target_decl_id != parent_decl_id) {
            if (self.resolveMemberDecl(
                ctx,
                target_decl_id,
                member_name,
            )) |decl_id| return decl_id;
        }
    }

    var struct_init_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, init_node)) |struct_init| {
        const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
        const type_decl_id = self.resolveTypeExprDecl(
            ctx,
            parent_decl_id,
            type_expr,
        ) orelse return null;
        return self.resolveMemberDecl(
            ctx,
            type_decl_id,
            member_name,
        );
    }

    var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const unwrapped_init = ast.unwrapNode(tree, init_node, .{});
    if (tree.fullContainerDecl(
        &container_decl_buffer,
        unwrapped_init,
    )) |container_decl| {
        return self.resolveContainerMember(
            ctx.file_store,
            parent_file_id,
            container_decl,
            member_name,
        );
    }

    return null;
}

/// Resolves a member from the type represented by a declaration.
///
/// This handles ordinary type annotations and type-value initializers such as
/// `const List = std.ArrayList(u8);` or `var list = List.init(allocator);`.
pub fn resolveDeclTypeMember(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveDeclTypeMember");
    defer zone.end();

    if (self.declResolvedTypeTarget(decl_id)) |target| {
        if (self.resolveTypeTargetMember(
            ctx,
            target,
            member_name,
        )) |member_decl_id| return member_decl_id;
    }

    const target = self.resolveDeclTypeTargetForValue(
        ctx,
        decl_id,
    ) orelse return null;
    return self.resolveTypeTargetMember(
        ctx,
        target,
        member_name,
    );
}

fn resolveTypeTargetMember(
    self: *DeclStore,
    ctx: ResolveContext,
    target: TypeTarget,
    member_name: []const u8,
) ?DeclId {
    return switch (target) {
        .decl => |type_decl_id| self.resolveMemberDecl(
            ctx,
            type_decl_id,
            member_name,
        ),
        .container => |container| blk: {
            const tree = ctx.file_store.fileTree(container.file_id);
            if (!nodeBelongsToTree(tree, container.node)) break :blk null;
            var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
            const container_decl = tree.fullContainerDecl(
                &container_decl_buffer,
                container.node,
            ) orelse break :blk null;
            break :blk self.resolveContainerMember(
                ctx.file_store,
                container.file_id,
                container_decl,
                member_name,
            );
        },
    };
}

/// Computes the concrete type target for a declaration's value in one root
/// context.
///
/// This is exposed so LintSession can cache targets per module.
pub fn resolveDeclTypeTargetForValue(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveDeclTypeTargetForValue");
    defer zone.end();

    return self.resolveDeclTypeTargetForValueDepth(
        ctx,
        decl_id,
        16,
    );
}

fn resolveDeclTypeTargetForValueDepth(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    remaining_depth: u8,
) ?TypeTarget {
    if (remaining_depth == 0) return null;

    if (self.declTypeNode(decl_id)) |type_node| {
        if (self.resolveTypeExprTarget(
            ctx,
            decl_id,
            type_node,
        )) |type_decl_id| return type_decl_id;
    }

    if (self.resolveDeclTypeDecl(
        ctx,
        decl_id,
    )) |type_decl_id| {
        if (type_decl_id == decl_id) return .{ .decl = type_decl_id };
        return self.resolveDeclTypeTargetForValueDepth(
            ctx,
            type_decl_id,
            remaining_depth - 1,
        ) orelse .{ .decl = type_decl_id };
    }

    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    const node = self.declAstNode(decl_id) orelse return null;
    if (node == .root) return .{ .decl = decl_id };

    const var_decl = tree.fullVarDecl(node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (!nodeBelongsToTree(tree, init_node)) return null;

    return self.resolveValueTypeTarget(
        ctx,
        decl_id,
        init_node,
    );
}

fn resolveMemberDeclFromType(
    self: *DeclStore,
    ctx: ResolveContext,
    parent_decl_id: DeclId,
    member_name: []const u8,
) ?DeclId {
    const type_node = self.declTypeNode(parent_decl_id) orelse return null;
    const type_decl_id = self.resolveTypeExprDecl(
        ctx,
        parent_decl_id,
        type_node,
    ) orelse return null;

    if (type_decl_id == parent_decl_id) return null;
    return self.resolveMemberDecl(
        ctx,
        type_decl_id,
        member_name,
    );
}

fn resolveValueTypeTarget(
    self: *DeclStore,
    ctx: ResolveContext,
    context_decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveValueTypeTarget");
    defer zone.end();

    const tree = ctx.file_store.fileTree(self.declFileId(context_decl_id));
    if (!nodeBelongsToTree(tree, value_node)) return null;
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });
    if (!nodeBelongsToTree(tree, node)) return null;

    var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node) != null) {
        const file_id = self.declFileId(context_decl_id);
        return if (self.declByAstNode(file_id, node)) |decl_id|
            .{ .decl = decl_id }
        else
            .{ .container = .{ .file_id = file_id, .node = node } };
    }

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const type_expr = if (tree.nodeTag(call.ast.fn_expr) == .field_access) type_expr: {
            const target_node, const call_name_token = tree.nodeData(call.ast.fn_expr).node_and_token;
            const call_name = tree.tokenSlice(call_name_token);
            if (std.mem.eql(u8, call_name, "init") or
                std.mem.eql(u8, call_name, "initCapacity"))
            {
                break :type_expr target_node;
            }
            break :type_expr node;
        } else node;

        return self.resolveTypeExprTarget(
            ctx,
            context_decl_id,
            type_expr,
        );
    }

    if (tree.nodeTag(node) == .field_access) {
        const target_node, _ = tree.nodeData(node).node_and_token;
        return self.resolveTypeExprTarget(
            ctx,
            context_decl_id,
            node,
        ) orelse self.resolveTypeExprTarget(
            ctx,
            context_decl_id,
            target_node,
        );
    }

    return self.resolveTypeExprTarget(
        ctx,
        context_decl_id,
        node,
    );
}

fn resolveTypeExprTarget(
    self: *DeclStore,
    ctx: ResolveContext,
    context_decl_id: DeclId,
    type_expr: std.zig.Ast.Node.Index,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveTypeExprTarget");
    defer zone.end();

    const tree = ctx.file_store.fileTree(self.declFileId(context_decl_id));
    if (!nodeBelongsToTree(tree, type_expr)) return null;
    const node = ast.unwrapNode(tree, type_expr, .{
        .unwrap_optional_unwrap = false,
    });
    if (!nodeBelongsToTree(tree, node)) return null;

    var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node) != null) {
        const file_id = self.declFileId(context_decl_id);
        return if (self.declByAstNode(file_id, node)) |decl_id|
            .{ .decl = decl_id }
        else
            .{ .container = .{ .file_id = file_id, .node = node } };
    }

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const immediate_callee_decl_id = self.resolveExprDecl(
            ctx,
            context_decl_id,
            call.ast.fn_expr,
        ) orelse return null;
        const callee_decl_id = self.resolveValueAliasDecl(
            ctx,
            immediate_callee_decl_id,
            16,
        );
        return self.resolveTypeFactoryResultTarget(
            ctx,
            callee_decl_id,
        );
    }

    const decl_id = self.resolveExprDecl(
        ctx,
        context_decl_id,
        node,
    ) orelse return null;

    const target_decl_id = self.resolveValueAliasDecl(
        ctx,
        decl_id,
        16,
    );
    if (target_decl_id == context_decl_id) return null;
    return self.resolveDeclTypeTargetForValueDepth(
        ctx,
        target_decl_id,
        16,
    ) orelse .{ .decl = target_decl_id };
}

pub fn resolveTypeFactoryResultTarget(
    self: *DeclStore,
    ctx: ResolveContext,
    fn_decl_id: DeclId,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveTypeFactoryResultTarget");
    defer zone.end();

    const file_id = self.declFileId(fn_decl_id);
    const tree = ctx.file_store.fileTree(file_id);
    const node = self.declAstNode(fn_decl_id) orelse return null;

    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const fn_decl = ast.fnDecl(
        tree,
        node,
        &fn_proto_buffer,
    ) orelse return null;

    if (TypeStore.summarizeFnProto(
        tree,
        fn_decl.proto,
        .summary,
    ).coarseType() != .fn_returns_type) return null;

    var it = ast.ChildIterator.init(tree, fn_decl.block);
    while (it.next(tree)) |child_node| {
        if (tree.nodeTag(child_node) != .@"return") continue;
        const return_expr = tree.nodeData(child_node).opt_node.unwrap() orelse continue;
        if (!nodeBelongsToTree(tree, return_expr)) continue;
        const expr = ast.unwrapNode(tree, return_expr, .{});
        if (!nodeBelongsToTree(tree, expr)) continue;

        var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_decl_buffer, expr) != null) {
            return if (self.declByAstNode(file_id, expr)) |decl_id|
                .{ .decl = decl_id }
            else
                .{ .container = .{ .file_id = file_id, .node = expr } };
        }

        return self.resolveTypeExprTarget(
            ctx.withParent(file_id),
            fn_decl_id,
            return_expr,
        );
    }

    return null;
}

fn resolveValueAliasDecl(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    remaining_depth: u8,
) DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveValueAliasDecl");
    defer zone.end();

    if (remaining_depth == 0) return decl_id;

    const file_id = self.declFileId(decl_id);
    const tree = ctx.file_store.fileTree(file_id);
    const node = self.declAstNode(decl_id) orelse return decl_id;
    const var_decl = tree.fullVarDecl(node) orelse return decl_id;
    const init_node = var_decl.ast.init_node.unwrap() orelse return decl_id;
    if (!nodeBelongsToTree(tree, init_node)) return decl_id;

    const target_decl_id = self.resolveExprDecl(
        ctx.withParent(file_id),
        decl_id,
        init_node,
    ) orelse return decl_id;

    if (target_decl_id == decl_id) return decl_id;
    return self.resolveValueAliasDecl(
        ctx.withParent(file_id),
        target_decl_id,
        remaining_depth - 1,
    );
}

fn nodeBelongsToTree(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return @intFromEnum(node) < tree.nodes.len;
}

fn resolveTypeExprDecl(
    self: *DeclStore,
    ctx: ResolveContext,
    decl_id: DeclId,
    type_node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveTypeExprDecl");
    defer zone.end();

    const tree = ctx.file_store.fileTree(self.declFileId(decl_id));
    return self.resolveExprDecl(
        ctx,
        decl_id,
        ast.unwrapNode(tree, type_node, .{}),
    );
}

fn resolveImportMember(
    self: *DeclStore,
    ctx: ResolveContext,
    parent_file_id: FileStore.FileId,
    init_node: std.zig.Ast.Node.Index,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveImportMember");
    defer zone.end();

    const key = ImportMemberKey.init(
        ctx,
        parent_file_id,
        init_node,
        member_name,
    );
    if (self.import_member_by_context.get(key)) |decl_id| {
        zone.setValue(1);
        return decl_id;
    }
    zone.setValue(0);

    const tree = ctx.file_store.fileTree(parent_file_id);

    var import_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const import_path = import_utils.writeImportPath(
        tree,
        init_node,
        &import_path_buffer,
    ) orelse {
        oom(self.import_member_by_context.put(
            self.runtime.sessionArena(),
            self.ownedImportMemberKey(key),
            null,
        ));
        return null;
    };

    const maybe_file_id = import_utils.resolveFile(
        ctx.withParent(parent_file_id),
        import_path,
    ) catch |e| {
        std.log.err("Failed to resolve import '{s}': {t}", .{ import_path, e });
        return null;
    };

    const decl_id = if (maybe_file_id) |file_id|
        self.resolveFileRootMember(ctx.file_store, file_id, member_name)
    else
        null;

    oom(self.import_member_by_context.put(
        self.runtime.sessionArena(),
        self.ownedImportMemberKey(key),
        decl_id,
    ));
    return decl_id;
}

fn ownedImportMemberKey(
    self: *DeclStore,
    key: ImportMemberKey,
) ImportMemberKey {
    var owned_key = key;
    owned_key.member_name = oom(self.runtime.sessionArena().dupe(
        u8,
        key.member_name,
    ));
    return owned_key;
}

fn isThisBuiltinCall(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@This"),
        else => return false,
    }
}

fn resolveContainerMember(
    self: *const DeclStore,
    file_store: *FileStore,
    file_id: FileStore.FileId,
    container_decl: std.zig.Ast.full.ContainerDecl,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveContainerMember");
    defer zone.end();

    const tree = file_store.fileTree(file_id);
    for (container_decl.ast.members) |member_node| {
        const name_token = ast.declNameToken(tree, member_node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), member_name)) continue;
        return self.declByAstNode(file_id, member_node);
    }
    return null;
}

fn resolveFileRootMember(
    self: *DeclStore,
    file_store: *FileStore,
    file_id: FileStore.FileId,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveFileRootMember");
    defer zone.end();

    _ = self.store(file_id, file_store);

    const root_decl_id = self.fileRootDecl(file_id) orelse return null;
    const root_scope_id = self.scopeForOwnerDecl(root_decl_id) orelse return null;
    return self.scopeDecl(root_scope_id, member_name);
}

fn lookupVisibleDecl(
    self: *const DeclStore,
    start_scope_id: ScopeId,
    name: []const u8,
    skip_decl_id: ?DeclId,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.lookupVisibleDecl");
    defer zone.end();

    var maybe_scope_id: ?ScopeId = start_scope_id;
    while (maybe_scope_id) |scope_id| {
        if (self.scopeDecl(scope_id, name)) |decl_id| {
            if (skip_decl_id != null and decl_id == skip_decl_id.?) return null;
            return decl_id;
        }
        maybe_scope_id = self.scopes.items(.parent_scope_id)[scope_id.toIndex()];
    }

    return null;
}

fn scopeForOwnerDecl(
    self: *const DeclStore,
    owner_decl_id: DeclId,
) ?ScopeId {
    const zone = tracy.traceNamed(@src(), "DeclStore.scopeForOwnerDecl");
    defer zone.end();

    return self.scope_id_by_owner_decl.get(owner_decl_id);
}

fn declByAstNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.declByAstNode");
    defer zone.end();

    return self.decl_id_by_ast_node.get(.init(file_id, node));
}

fn fileRootDecl(
    self: *const DeclStore,
    file_id: FileStore.FileId,
) ?DeclId {
    return self.decl_id_by_ast_node.get(.init(file_id, .root));
}

/// Appends a scope and returns its typed id.
fn appendScope(
    self: *DeclStore,
    file_id: FileStore.FileId,
    owner_node: std.zig.Ast.Node.Index,
    parent_scope_id: ?ScopeId,
    owner_decl_id: ?DeclId,
) ScopeId {
    const scope_id: ScopeId = .fromIndex(self.scopes.len);
    oom(self.scopes.append(self.runtime.sessionArena(), .{
        .file_id = file_id,
        .owner_node = owner_node,
        .parent_scope_id = parent_scope_id,
        .owner_decl_id = owner_decl_id,
        .decl_id_by_name = .empty,
    }));
    oom(self.scope_id_by_owner_node.putNoClobber(
        self.runtime.sessionArena(),
        .init(file_id, owner_node),
        scope_id,
    ));
    if (owner_decl_id) |decl_id| {
        oom(self.scope_id_by_owner_decl.putNoClobber(
            self.runtime.sessionArena(),
            decl_id,
            scope_id,
        ));
    }
    return scope_id;
}

/// Appends a declaration record and returns its typed id.
fn appendDecl(
    self: *DeclStore,
    file_id: FileStore.FileId,
    name_token: ?std.zig.Ast.TokenIndex,
    ast_node: ?std.zig.Ast.Node.Index,
    type_node: ?std.zig.Ast.Node.Index,
    scope_id: ?ScopeId,
    kind: DeclKind,
) DeclId {
    const decl_id: DeclId = .fromIndex(self.decls.len);
    oom(self.decls.append(self.runtime.sessionArena(), .{
        .name_token = name_token,
        .ast_node = ast_node,
        .type_node = type_node,
        .scope_id = scope_id,
        .file_id = file_id,
        .kind = kind,
    }));
    const file_decls_entry = oom(self.decl_ids_by_file.getOrPut(
        self.runtime.sessionArena(),
        file_id,
    ));
    if (!file_decls_entry.found_existing) {
        file_decls_entry.value_ptr.* = .empty;
    }
    oom(file_decls_entry.value_ptr.append(
        self.runtime.sessionArena(),
        decl_id,
    ));
    if (ast_node) |node| {
        oom(self.decl_id_by_ast_node.putNoClobber(
            self.runtime.sessionArena(),
            .init(file_id, node),
            decl_id,
        ));
    }
    return decl_id;
}

/// Inserts a named declaration into a scope unless the name is ignored or already present.
fn putDecl(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    name_token: std.zig.Ast.TokenIndex,
    ast_node: ?std.zig.Ast.Node.Index,
    type_node: ?std.zig.Ast.Node.Index,
    kind: DeclKind,
) ?DeclId {
    const name = tree.tokenSlice(name_token);
    if (std.mem.eql(u8, name, "_")) return null;
    if (self.scopeDecl(scope_id, name) != null) return null;

    const decl_id = self.appendDecl(
        file_id,
        name_token,
        ast_node,
        type_node,
        scope_id,
        kind,
    );
    oom(self.scopes.items(.decl_id_by_name)[scope_id.toIndex()].putNoClobber(
        self.runtime.sessionArena(),
        name,
        decl_id,
    ));

    return decl_id;
}

/// Extracts a declaration name from an AST node and inserts it into a scope.
fn putNodeDecl(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
    kind: DeclKind,
) ?DeclId {
    return self.putDecl(
        tree,
        file_id,
        scope_id,
        ast.declNameToken(tree, node) orelse return null,
        node,
        ast.declTypeNode(tree, node),
        kind,
    );
}

/// Walks a node and dispatches to the handler that owns its scope semantics.
fn walkNode(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.walkNode");
    defer zone.end();

    switch (tree.nodeTag(node)) {
        .root => unreachable,

        .container_decl,
        .container_decl_trailing,
        .container_decl_arg,
        .container_decl_arg_trailing,
        .container_decl_two,
        .container_decl_two_trailing,
        .tagged_union,
        .tagged_union_trailing,
        .tagged_union_enum_tag,
        .tagged_union_enum_tag_trailing,
        .tagged_union_two,
        .tagged_union_two_trailing,
        => {
            const container_scope_id = self.appendScope(
                file_id,
                node,
                scope_id,
                null,
            );
            self.walkContainer(
                tree,
                file_id,
                container_scope_id,
                node,
            );
        },

        .fn_decl,
        .fn_proto,
        .fn_proto_one,
        .fn_proto_simple,
        .fn_proto_multi,
        => self.walkFn(
            tree,
            file_id,
            scope_id,
            node,
        ),

        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => self.walkBlock(
            tree,
            file_id,
            scope_id,
            node,
        ),

        else => self.walkChildren(
            tree,
            file_id,
            scope_id,
            node,
        ),
    }
}

/// Walks a container-like node and registers its direct member declarations.
fn walkContainer(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.walkContainer");
    defer zone.end();

    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container_decl = tree.fullContainerDecl(&buffer, node) orelse return;
    const is_struct = node == .root or tree.tokenTag(container_decl.ast.main_token) == .keyword_struct;

    for (container_decl.ast.members) |member| {
        self.walkNode(
            tree,
            file_id,
            scope_id,
            member,
        );

        switch (tree.nodeTag(member)) {
            .container_field,
            .container_field_init,
            .container_field_align,
            => {
                var field = tree.fullContainerField(member).?;
                if (is_struct and field.ast.tuple_like) continue;
                field.convertToNonTupleLike(&tree);
                if (field.ast.tuple_like) continue;

                const name_token = field.ast.main_token;
                if (tree.tokenTag(name_token) == .identifier) {
                    _ = self.putDecl(
                        tree,
                        file_id,
                        scope_id,
                        name_token,
                        member,
                        field.ast.type_expr.unwrap(),
                        .field,
                    );
                }
            },

            .fn_decl,
            .fn_proto,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_proto_multi,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => _ = self.putNodeDecl(
                tree,
                file_id,
                scope_id,
                member,
                .declaration,
            ),

            else => {},
        }
    }
}

/// Walks a function prototype or declaration in its own function scope.
fn walkFn(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    parent_scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.walkFn");
    defer zone.end();

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buffer, node).?;
    const fn_scope_id = self.appendScope(
        file_id,
        node,
        parent_scope_id,
        null,
    );

    var it = fn_proto.iterate(&tree);
    while (it.next()) |param| {
        if (param.name_token) |name_token|
            _ = self.putDecl(
                tree,
                file_id,
                fn_scope_id,
                name_token,
                null,
                param.type_expr,
                .declaration,
            );

        if (param.type_expr) |type_expr|
            self.walkNode(
                tree,
                file_id,
                fn_scope_id,
                type_expr,
            );
    }

    if (fn_proto.ast.return_type.unwrap()) |return_type|
        self.walkNode(
            tree,
            file_id,
            fn_scope_id,
            return_type,
        );

    if (tree.nodeTag(node) == .fn_decl) {
        _, const block = tree.nodeData(node).node_and_node;
        self.walkNode(
            tree,
            file_id,
            fn_scope_id,
            block,
        );
    }
}

/// Walks a block in its own block scope and registers statement-local declarations.
fn walkBlock(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    parent_scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.walkBlock");
    defer zone.end();

    const block_scope_id = self.appendScope(
        file_id,
        node,
        parent_scope_id,
        null,
    );
    if (blockLabel(tree, node)) |label_token| {
        _ = self.putDecl(
            tree,
            file_id,
            block_scope_id,
            label_token,
            node,
            null,
            .label,
        );
    }

    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node).?;

    for (statements) |statement| {
        self.walkNode(
            tree,
            file_id,
            block_scope_id,
            statement,
        );

        switch (tree.nodeTag(statement)) {
            .global_var_decl,
            .local_var_decl,
            .aligned_var_decl,
            .simple_var_decl,
            => _ = self.putNodeDecl(
                tree,
                file_id,
                block_scope_id,
                statement,
                .declaration,
            ),

            .assign_destructure => {
                const assign_destructure = tree.assignDestructure(statement);
                for (assign_destructure.ast.variables) |variable|
                    _ = self.putNodeDecl(
                        tree,
                        file_id,
                        block_scope_id,
                        variable,
                        .declaration,
                    );
            },

            else => {},
        }
    }
}

/// Walks direct AST children using the shared child iterator.
fn walkChildren(
    self: *DeclStore,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.walkChildren");
    defer zone.end();

    var it = ast.ChildIterator.init(tree, node);
    while (it.next(tree)) |child|
        self.walkNode(
            tree,
            file_id,
            scope_id,
            child,
        );
}

/// Returns the label token for a labeled block, if present.
///
/// For example, "block_label" token index in:
///
/// ```
/// const age:u32 = block_label: {
///    break :block_label 10;
/// };
/// ```
fn blockLabel(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.TokenIndex {
    const main_token = tree.nodeMainToken(node);
    if (main_token < 2) return null;
    if (tree.tokenTag(main_token - 1) != .colon) return null;
    if (tree.tokenTag(main_token - 2) != .identifier) return null;
    return main_token - 2;
}

/// Iterate declarations within a given file.
pub fn fileDeclIterator(self: *const DeclStore, file_id: FileStore.FileId) FileDeclIterator {
    return .{
        .decl_ids = if (self.decl_ids_by_file.get(file_id)) |decl_ids|
            decl_ids.items
        else
            &.{},
    };
}

pub const FileDeclIterator = struct {
    decl_ids: []const DeclId,
    index: usize = 0,

    pub fn next(self: *FileDeclIterator) ?DeclId {
        if (self.index >= self.decl_ids.len) return null;
        defer self.index += 1;
        return self.decl_ids[self.index];
    }
};

const ast = @import("../ast.zig");
const FileStore = @import("FileStore.zig");
const import_utils = @import("imports.zig");
const LintRuntime = @import("LintRuntime.zig");
const ModuleStore = @import("ModuleStore.zig");
const std = @import("std");
const TypeStore = @import("TypeStore.zig");
const ResolveContext = import_utils.ResolveContext;
const tracy = @import("tracy");
const oom = @import("../allocations.zig").oom;
