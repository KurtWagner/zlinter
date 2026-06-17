const DeclStore = @This();

// TODO: #149 - decide on error handling, specifically OOM. This module just panics to keep it simpler

decls: std.MultiArrayList(Decl) = .empty,
scopes: std.MultiArrayList(Scope) = .empty,
decl_by_ast_node: std.AutoHashMapUnmanaged(DeclAstNodeKey, DeclId) = .empty,
scope_by_owner: std.AutoHashMapUnmanaged(ScopeOwnerKey, ScopeId) = .empty,

// TODO: #149 - use better pattern for passing these common things around
gpa: std.mem.Allocator,
io: std.Io,
/// externally owned
zig_lib_directory: []const u8,

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
    decl_by_name: std.StringHashMapUnmanaged(DeclId),
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
    gpa: std.mem.Allocator,
) DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.store");
    defer zone.end();

    // TODO: #149 - think abou multiple modules

    // TODO: #149 - optimise this
    for (self.decls.items(.file_id), 0..) |existing_file_id, decl_id| {
        if (existing_file_id == file_id) return .fromIndex(decl_id);
    }

    const tree = file_store.fileTree(file_id);

    const root_decl_id = self.appendDecl(
        gpa,
        file_id,
        null,
        .root,
        null,
        null,
        .declaration,
    );

    const root_scope_id = self.appendScope(
        gpa,
        file_id,
        .root,
        null,
        root_decl_id,
    );

    self.walkContainer(
        gpa,
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
    file_store: *FileStore,
    module_store: *const ModuleStore,
    type_store: *TypeStore,
    gpa: std.mem.Allocator,
) void {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveFileTypes");
    defer zone.end();

    _ = self.store(file_id, file_store, gpa);

    var it = self.fileDeclIterator(file_id);
    while (it.next()) |decl_id| {
        const type_id = if (self.resolveDeclType(
            file_store,
            module_store,
            decl_id,
        )) |summary|
            type_store.store(gpa, summary)
        else
            null;
        const type_target = self.resolveDeclTypeTargetForValue(
            file_store,
            module_store,
            decl_id,
        );

        self.decls.items(.resolved_type)[decl_id.toIndex()] = type_id;
        self.decls.items(.resolved_type_target)[decl_id.toIndex()] = type_target;
    }
}

/// Releases all declaration and scope storage owned by this store.
pub fn deinit(self: *DeclStore, gpa: std.mem.Allocator) void {
    for (self.scopes.items(.decl_by_name)) |*decl_by_name|
        decl_by_name.deinit(gpa);

    self.decl_by_ast_node.deinit(gpa);
    self.scope_by_owner.deinit(gpa);
    self.decls.deinit(gpa);
    self.scopes.deinit(gpa);
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
pub fn resolveNodeDecl(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    context_decl_id: DeclId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveNodeDecl");
    defer zone.end();

    const file_id = self.declFileId(context_decl_id);
    const tree = file_store.fileTree(file_id);
    const unwrapped = ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    if (isThisBuiltinCall(tree, unwrapped)) {
        return self.rootDecl(file_id);
    }

    const scope_id = self.declScopeId(context_decl_id) orelse return null;
    return self.resolveExprDeclFromScope(
        file_store,
        module_store,
        file_id,
        scope_id,
        node,
        context_decl_id,
    );
}

/// Resolves an expression node to the declaration it names from a lexical scope.
pub fn resolveNodeDeclFromScope(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveNodeDeclFromScope");
    defer zone.end();

    const tree = file_store.fileTree(file_id);
    const unwrapped = ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    if (isThisBuiltinCall(tree, unwrapped))
        return self.rootDecl(file_id);

    return self.resolveExprDeclFromScope(
        file_store,
        module_store,
        file_id,
        scope_id,
        node,
        null,
    );
}

/// Returns the stored declaration represented by this AST node, if any.
///
/// This is a direct node-to-declaration lookup, it does not resolve identifier
/// references or field accesses.
pub fn declByNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    return self.declByAstNode(file_id, node);
}

pub fn rootDecl(
    self: *const DeclStore,
    file_id: FileStore.FileId,
) ?DeclId {
    return self.fileRootDecl(file_id);
}

/// Returns the lexical scope owned by an AST node, if one was recorded.
pub fn scopeByNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?ScopeId {
    const zone = tracy.traceNamed(@src(), "DeclStore.scopeByNode");
    defer zone.end();

    return self.scope_by_owner.get(.init(file_id, node));
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
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveDeclTypeDecl");
    defer zone.end();

    const type_node = self.declTypeNode(decl_id) orelse return null;
    return self.resolveTypeExprDecl(
        file_store,
        module_store,
        decl_id,
        type_node,
    );
}

/// Looks up a declaration by name directly within a scope.
fn scopeDecl(self: *const DeclStore, scope_id: ScopeId, name: []const u8) ?DeclId {
    return self.scopes.items(.decl_by_name)[scope_id.toIndex()].get(name);
}

fn resolveDeclType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    const node = self.declAstNode(decl_id) orelse {
        const type_node = self.declTypeNode(decl_id) orelse return null;
        return TypeStore.summarizeTypeNode(tree, type_node);
    };

    if (node == .root) return TypeStore.summarizeRoot();

    if (tree.fullVarDecl(node)) |var_decl| {
        return self.resolveVarDeclType(
            file_store,
            module_store,
            decl_id,
            var_decl,
        );
    }

    if (tree.fullContainerField(node)) |field| {
        return self.resolveContainerFieldType(
            file_store,
            module_store,
            decl_id,
            field,
        );
    }

    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return TypeStore.summarizeFnProto(tree, fn_proto, false);
    }

    return null;
}

fn resolveVarDeclType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    var_decl: std.zig.Ast.full.VarDecl,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    if (var_decl.ast.type_node.unwrap()) |type_node| {
        return valueSummaryFromTypeAnnotation(tree, type_node) orelse
            TypeStore.summarizeTypeNode(tree, type_node);
    }
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (self.resolveCallReturnType(
        file_store,
        module_store,
        decl_id,
        init_node,
    )) |summary| return summary;
    if (self.resolveValueAliasType(
        file_store,
        module_store,
        decl_id,
        init_node,
    )) |summary| return summary;
    if (self.resolveInstanceValueType(
        file_store,
        module_store,
        decl_id,
        init_node,
    )) |summary| return summary;
    return TypeStore.summarizeValueNode(tree, init_node);
}

fn resolveContainerFieldType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    field: std.zig.Ast.full.ContainerField,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    if (field.ast.type_expr.unwrap()) |type_node| {
        return valueSummaryFromTypeAnnotation(tree, type_node) orelse
            TypeStore.summarizeTypeNode(tree, type_node);
    }
    const value_node = field.ast.value_expr.unwrap() orelse return null;
    if (self.resolveCallReturnType(
        file_store,
        module_store,
        decl_id,
        value_node,
    )) |summary| return summary;
    if (self.resolveValueAliasType(
        file_store,
        module_store,
        decl_id,
        value_node,
    )) |summary| return summary;
    if (self.resolveInstanceValueType(
        file_store,
        module_store,
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

fn resolveValueAliasType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    const target_node = if (tree.nodeTag(node) == .address_of)
        tree.nodeData(node).node
    else
        node;

    const target_decl_id = self.resolveExprDecl(
        file_store,
        module_store,
        decl_id,
        target_node,
    ) orelse return null;
    if (target_decl_id == decl_id) return null;

    const summary = self.resolveDeclType(
        file_store,
        module_store,
        target_decl_id,
    ) orelse return null;

    return switch (summary) {
        .unknown, .other, .primitive => null,
        else => summary,
    };
}

fn resolveInstanceValueType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    var struct_init_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
        const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
        const type_summary = self.resolveTypeExprValueSummary(
            file_store,
            module_store,
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
            file_store,
            module_store,
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
    file_store: *FileStore,
    module_store: *const ModuleStore,
    context_decl_id: DeclId,
    type_expr: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(context_decl_id));
    const summary = TypeStore.summarizeValueNode(tree, type_expr) orelse .unknown;
    switch (summary) {
        .unknown => {},
        else => return summary,
    }

    const target = self.resolveTypeExprTarget(
        file_store,
        module_store,
        context_decl_id,
        type_expr,
    ) orelse return null;

    return self.summarizeTypeTargetValue(
        file_store,
        module_store,
        target,
    );
}

fn instanceSummaryFromTypeSummary(summary: TypeStore.TypeSummary) ?TypeStore.TypeSummary {
    return switch (summary.typeValueKind() orelse return null) {
        .@"struct" => .{ .instance = .{ .kind = .@"struct" } },
        .@"union" => .{ .instance = .{ .kind = .@"union" } },
        .@"enum" => .{ .instance = .{ .kind = .@"enum" } },
        .@"opaque" => .{ .instance = .{ .kind = .@"opaque" } },
        .error_set => .{ .instance = .{ .kind = .error_set } },
        else => null,
    };
}

fn resolveCallReturnType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;
    const callee_decl_id = self.resolveExprDecl(
        file_store,
        module_store,
        decl_id,
        call.ast.fn_expr,
    ) orelse return null;

    const return_type = self.resolveFunctionDeclReturnType(file_store, callee_decl_id) orelse return null;
    if (return_type.coarseType() != .type) return return_type;

    const target = self.resolveTypeFactoryResultTarget(
        file_store,
        module_store,
        callee_decl_id,
    ) orelse return return_type;

    return self.summarizeTypeTargetValue(
        file_store,
        module_store,
        target,
    ) orelse return_type;
}

fn summarizeTypeTargetValue(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    target: TypeTarget,
) ?TypeStore.TypeSummary {
    return switch (target) {
        .decl => |decl_id| self.resolveDeclType(
            file_store,
            module_store,
            decl_id,
        ),
        .container => |container| blk: {
            const tree = file_store.fileTree(container.file_id);
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
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    expr_node: std.zig.Ast.Node.Index,
) ?DeclId {
    const file_id = self.declFileId(decl_id);
    const scope_id = self.declScopeId(decl_id) orelse return null;
    return self.resolveExprDeclFromScope(
        file_store,
        module_store,
        file_id,
        scope_id,
        expr_node,
        decl_id,
    );
}

fn resolveExprDeclFromScope(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    expr_node: std.zig.Ast.Node.Index,
    skip_decl_id: ?DeclId,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveExprDeclFromScope");
    defer zone.end();

    const tree = file_store.fileTree(file_id);
    const node = ast.unwrapNode(tree, expr_node, .{
        .unwrap_optional_unwrap = false,
    });

    switch (tree.nodeTag(node)) {
        .identifier => {
            return self.lookupVisibleDecl(
                scope_id,
                tree.getNodeSource(node),
                skip_decl_id,
            );
        },
        .field_access => {
            const target_node, const member_token = tree.nodeData(node).node_and_token;
            if (self.resolveImportMember(
                file_store,
                module_store,
                file_id,
                target_node,
                tree.tokenSlice(member_token),
            )) |decl_id| return decl_id;

            const target_decl_id = self.resolveExprDeclFromScope(
                file_store,
                module_store,
                file_id,
                scope_id,
                target_node,
                skip_decl_id,
            ) orelse return null;

            return self.resolveMemberDecl(
                file_store,
                module_store,
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
    file_store: *FileStore,
    module_store: *const ModuleStore,
    parent_decl_id: DeclId,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveMemberDecl");
    defer zone.end();

    if (self.resolveMemberDeclFromType(
        file_store,
        module_store,
        parent_decl_id,
        member_name,
    )) |decl_id| {
        return decl_id;
    }

    const node = self.declAstNode(parent_decl_id) orelse return null;

    const parent_file_id = self.declFileId(parent_decl_id);
    const tree = file_store.fileTree(parent_file_id);
    if (node == .root) return self.resolveFileRootMember(
        file_store,
        parent_file_id,
        member_name,
    );

    const var_decl = tree.fullVarDecl(node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (!nodeBelongsToTree(tree, init_node)) return null;

    if (self.resolveImportMember(
        file_store,
        module_store,
        parent_file_id,
        init_node,
        member_name,
    )) |decl_id| {
        return decl_id;
    }

    if (self.resolveExprDecl(
        file_store,
        module_store,
        parent_decl_id,
        init_node,
    )) |target_decl_id| {
        if (target_decl_id != parent_decl_id) {
            if (self.resolveMemberDecl(
                file_store,
                module_store,
                target_decl_id,
                member_name,
            )) |decl_id| return decl_id;
        }
    }

    var struct_init_buffer: [2]std.zig.Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, init_node)) |struct_init| {
        const type_expr = struct_init.ast.type_expr.unwrap() orelse return null;
        const type_decl_id = self.resolveTypeExprDecl(
            file_store,
            module_store,
            parent_decl_id,
            type_expr,
        ) orelse return null;
        return self.resolveMemberDecl(
            file_store,
            module_store,
            type_decl_id,
            member_name,
        );
    }

    var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const init = ast.unwrapNode(tree, init_node, .{});
    if (tree.fullContainerDecl(
        &container_decl_buffer,
        init,
    )) |container_decl| {
        return self.resolveContainerMember(
            file_store,
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
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveDeclTypeMember");
    defer zone.end();

    if (self.declResolvedTypeTarget(decl_id)) |target| {
        if (self.resolveTypeTargetMember(
            file_store,
            module_store,
            target,
            member_name,
        )) |member_decl_id| return member_decl_id;
    }

    const target = self.resolveDeclTypeTargetForValue(
        file_store,
        module_store,
        decl_id,
    ) orelse return null;
    return self.resolveTypeTargetMember(
        file_store,
        module_store,
        target,
        member_name,
    );
}

fn resolveTypeTargetMember(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    target: TypeTarget,
    member_name: []const u8,
) ?DeclId {
    return switch (target) {
        .decl => |type_decl_id| self.resolveMemberDecl(
            file_store,
            module_store,
            type_decl_id,
            member_name,
        ),
        .container => |container| blk: {
            const tree = file_store.fileTree(container.file_id);
            if (!nodeBelongsToTree(tree, container.node)) break :blk null;
            var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;
            const container_decl = tree.fullContainerDecl(
                &container_decl_buffer,
                container.node,
            ) orelse break :blk null;
            break :blk self.resolveContainerMember(
                file_store,
                container.file_id,
                container_decl,
                member_name,
            );
        },
    };
}

fn resolveDeclTypeTargetForValue(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveDeclTypeTargetForValue");
    defer zone.end();

    return self.resolveDeclTypeTargetForValueDepth(
        file_store,
        module_store,
        decl_id,
        16,
    );
}

fn resolveDeclTypeTargetForValueDepth(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    remaining_depth: u8,
) ?TypeTarget {
    if (remaining_depth == 0) return null;

    if (self.declTypeNode(decl_id)) |type_node| {
        if (self.resolveTypeExprTarget(
            file_store,
            module_store,
            decl_id,
            type_node,
        )) |type_decl_id| return type_decl_id;
    }

    if (self.resolveDeclTypeDecl(
        file_store,
        module_store,
        decl_id,
    )) |type_decl_id| {
        if (type_decl_id == decl_id) return .{ .decl = type_decl_id };
        return self.resolveDeclTypeTargetForValueDepth(
            file_store,
            module_store,
            type_decl_id,
            remaining_depth - 1,
        ) orelse .{ .decl = type_decl_id };
    }

    const tree = file_store.fileTree(self.declFileId(decl_id));
    const node = self.declAstNode(decl_id) orelse return null;
    if (node == .root) return .{ .decl = decl_id };

    const var_decl = tree.fullVarDecl(node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (!nodeBelongsToTree(tree, init_node)) return null;

    return self.resolveValueTypeTarget(
        file_store,
        module_store,
        decl_id,
        init_node,
    );
}

fn resolveMemberDeclFromType(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    parent_decl_id: DeclId,
    member_name: []const u8,
) ?DeclId {
    const type_node = self.declTypeNode(parent_decl_id) orelse return null;
    const type_decl_id = self.resolveTypeExprDecl(
        file_store,
        module_store,
        parent_decl_id,
        type_node,
    ) orelse return null;

    if (type_decl_id == parent_decl_id) return null;
    return self.resolveMemberDecl(
        file_store,
        module_store,
        type_decl_id,
        member_name,
    );
}

fn resolveValueTypeTarget(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    context_decl_id: DeclId,
    value_node: std.zig.Ast.Node.Index,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveValueTypeTarget");
    defer zone.end();

    const tree = file_store.fileTree(self.declFileId(context_decl_id));
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
            file_store,
            module_store,
            context_decl_id,
            type_expr,
        );
    }

    if (tree.nodeTag(node) == .field_access) {
        const target_node, _ = tree.nodeData(node).node_and_token;
        return self.resolveTypeExprTarget(
            file_store,
            module_store,
            context_decl_id,
            node,
        ) orelse self.resolveTypeExprTarget(
            file_store,
            module_store,
            context_decl_id,
            target_node,
        );
    }

    return self.resolveTypeExprTarget(
        file_store,
        module_store,
        context_decl_id,
        node,
    );
}

fn resolveTypeExprTarget(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    context_decl_id: DeclId,
    type_expr: std.zig.Ast.Node.Index,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveTypeExprTarget");
    defer zone.end();

    const tree = file_store.fileTree(self.declFileId(context_decl_id));
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
            file_store,
            module_store,
            context_decl_id,
            call.ast.fn_expr,
        ) orelse return null;
        const callee_decl_id = self.resolveValueAliasDecl(
            file_store,
            module_store,
            immediate_callee_decl_id,
            16,
        );
        return self.resolveTypeFactoryResultTarget(
            file_store,
            module_store,
            callee_decl_id,
        );
    }

    const decl_id = self.resolveExprDecl(
        file_store,
        module_store,
        context_decl_id,
        node,
    ) orelse return null;

    const target_decl_id = self.resolveValueAliasDecl(
        file_store,
        module_store,
        decl_id,
        16,
    );
    if (target_decl_id == context_decl_id) return null;
    return self.resolveDeclTypeTargetForValueDepth(
        file_store,
        module_store,
        target_decl_id,
        16,
    ) orelse .{ .decl = target_decl_id };
}

pub fn resolveTypeFactoryResultTarget(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    fn_decl_id: DeclId,
) ?TypeTarget {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveTypeFactoryResultTarget");
    defer zone.end();

    const file_id = self.declFileId(fn_decl_id);
    const tree = file_store.fileTree(file_id);
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
        false,
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
            file_store,
            module_store,
            fn_decl_id,
            return_expr,
        );
    }

    return null;
}

fn resolveValueAliasDecl(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    remaining_depth: u8,
) DeclId {
    if (remaining_depth == 0) return decl_id;

    const file_id = self.declFileId(decl_id);
    const tree = file_store.fileTree(file_id);
    const node = self.declAstNode(decl_id) orelse return decl_id;
    const var_decl = tree.fullVarDecl(node) orelse return decl_id;
    const init_node = var_decl.ast.init_node.unwrap() orelse return decl_id;
    if (!nodeBelongsToTree(tree, init_node)) return decl_id;

    const target_decl_id = self.resolveExprDecl(
        file_store,
        module_store,
        decl_id,
        init_node,
    ) orelse return decl_id;

    if (target_decl_id == decl_id) return decl_id;
    return self.resolveValueAliasDecl(
        file_store,
        module_store,
        target_decl_id,
        remaining_depth - 1,
    );
}

fn nodeBelongsToTree(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return @intFromEnum(node) < tree.nodes.len;
}

fn resolveTypeExprDecl(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    decl_id: DeclId,
    type_node: std.zig.Ast.Node.Index,
) ?DeclId {
    const tree = file_store.fileTree(self.declFileId(decl_id));
    return self.resolveExprDecl(
        file_store,
        module_store,
        decl_id,
        ast.unwrapNode(tree, type_node, .{}),
    );
}

fn resolveImportMember(
    self: *DeclStore,
    file_store: *FileStore,
    module_store: *const ModuleStore,
    parent_file_id: FileStore.FileId,
    init_node: std.zig.Ast.Node.Index,
    member_name: []const u8,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.resolveImportMember");
    defer zone.end();

    const tree = file_store.fileTree(parent_file_id);

    const parent_abs_path = file_store.fileAbsPath(parent_file_id);
    const parent_file_dir = std.fs.path.dirname(parent_abs_path) orelse ".";

    var import_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const import_path = writeImportPath(
        tree,
        init_node,
        &import_path_buffer,
    ) orelse
        return null;

    const import_kind: files.Import.Kind = .init(import_path);
    const maybe_file_id: ?FileStore.FileId = file_id: switch (import_kind) {
        .relative => file_store.resolve(
            import_path,
            self.io,
            self.gpa,
            parent_file_dir,
        ) catch |e| {
            std.log.err("Failed to resolve '{s}': {t}", .{ import_path, e });
            break :file_id null;
        },
        .stdlib => file_store.resolveStdLib(
            self.io,
            self.gpa,
            self.zig_lib_directory,
        ) catch |e| {
            std.log.err("Failed to stdlib: {t}", .{e});
            break :file_id null;
        },
        // TODO: #149 - handle "root" and "builtin" imports.
        .builtin => null,
        .root => null,
        .module => id: {
            const parent_module_id = module_store.moduleForRootFile(parent_file_id) orelse break :id null;
            const imported_module_id = module_store.namedImport(
                parent_module_id,
                import_path,
            ) orelse break :id null;
            break :id module_store.rootFile(imported_module_id);
        },
    };

    return if (maybe_file_id) |file_id|
        self.resolveFileRootMember(file_store, file_id, member_name)
    else
        null;
}

fn writeImportPath(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    buffer: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {},
        else => return null,
    }

    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;

    var params_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&params_buffer, node) orelse return null;
    if (params.len != 1) return null;

    const import_arg = params[0];
    if (tree.nodeTag(import_arg) != .string_literal) return null;

    const raw_import = tree.tokenSlice(tree.nodeMainToken(import_arg));
    var writer: std.Io.Writer = .fixed(buffer);

    return switch (std.zig.string_literal.parseWrite(&writer, raw_import) catch return null) {
        .success => path: {
            writer.flush() catch return null;
            break :path writer.buffer[0..writer.end];
        },
        .failure => null,
    };
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

    _ = self.store(file_id, file_store, self.gpa);

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

    for (self.scopes.items(.owner_decl_id), 0..) |maybe_owner_decl_id, index| {
        if (maybe_owner_decl_id == owner_decl_id) return .fromIndex(index);
    }

    return null;
}

fn declByAstNode(
    self: *const DeclStore,
    file_id: FileStore.FileId,
    node: std.zig.Ast.Node.Index,
) ?DeclId {
    const zone = tracy.traceNamed(@src(), "DeclStore.declByAstNode");
    defer zone.end();

    return self.decl_by_ast_node.get(.init(file_id, node));
}

fn fileRootDecl(
    self: *const DeclStore,
    file_id: FileStore.FileId,
) ?DeclId {
    for (
        self.decls.items(.file_id),
        self.decls.items(.name_token),
        self.decls.items(.ast_node),
        0..,
    ) |decl_file_id, name_token, ast_node, index| {
        if (decl_file_id != file_id) continue;
        if (name_token != null) continue;
        if (ast_node == null or ast_node.? != .root) continue;

        return .fromIndex(index);
    }

    return null;
}

/// Appends a scope and returns its typed id.
fn appendScope(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    file_id: FileStore.FileId,
    owner_node: std.zig.Ast.Node.Index,
    parent_scope_id: ?ScopeId,
    owner_decl_id: ?DeclId,
) ScopeId {
    const scope_id: ScopeId = .fromIndex(self.scopes.len);
    self.scopes.append(gpa, .{
        .file_id = file_id,
        .owner_node = owner_node,
        .parent_scope_id = parent_scope_id,
        .owner_decl_id = owner_decl_id,
        .decl_by_name = .empty,
    }) catch @panic("OOM");
    self.scope_by_owner.putNoClobber(
        gpa,
        .init(file_id, owner_node),
        scope_id,
    ) catch @panic("OOM");
    return scope_id;
}

/// Appends a declaration record and returns its typed id.
fn appendDecl(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    file_id: FileStore.FileId,
    name_token: ?std.zig.Ast.TokenIndex,
    ast_node: ?std.zig.Ast.Node.Index,
    type_node: ?std.zig.Ast.Node.Index,
    scope_id: ?ScopeId,
    kind: DeclKind,
) DeclId {
    const decl_id: DeclId = .fromIndex(self.decls.len);
    self.decls.append(gpa, .{
        .name_token = name_token,
        .ast_node = ast_node,
        .type_node = type_node,
        .scope_id = scope_id,
        .file_id = file_id,
        .kind = kind,
    }) catch @panic("OOM");
    if (ast_node) |node| {
        self.decl_by_ast_node.putNoClobber(
            gpa,
            .init(file_id, node),
            decl_id,
        ) catch @panic("OOM");
    }
    return decl_id;
}

/// Inserts a named declaration into a scope unless the name is ignored or already present.
fn putDecl(
    self: *DeclStore,
    gpa: std.mem.Allocator,
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
        gpa,
        file_id,
        name_token,
        ast_node,
        type_node,
        scope_id,
        kind,
    );
    self.scopes.items(.decl_by_name)[scope_id.toIndex()].putNoClobber(
        gpa,
        name,
        decl_id,
    ) catch @panic("OOM");

    return decl_id;
}

/// Extracts a declaration name from an AST node and inserts it into a scope.
fn putNodeDecl(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
    kind: DeclKind,
) ?DeclId {
    return self.putDecl(
        gpa,
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
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
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
                gpa,
                file_id,
                node,
                scope_id,
                null,
            );
            self.walkContainer(
                gpa,
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
            gpa,
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
            gpa,
            tree,
            file_id,
            scope_id,
            node,
        ),

        else => self.walkChildren(
            gpa,
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
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container_decl = tree.fullContainerDecl(&buffer, node) orelse return;
    const is_struct = node == .root or tree.tokenTag(container_decl.ast.main_token) == .keyword_struct;

    for (container_decl.ast.members) |member| {
        self.walkNode(
            gpa,
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
                        gpa,
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
            => _ = self.putNodeDecl(gpa, tree, file_id, scope_id, member, .declaration),

            else => {},
        }
    }
}

/// Walks a function prototype or declaration in its own function scope.
fn walkFn(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    parent_scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buffer, node).?;
    const fn_scope_id = self.appendScope(
        gpa,
        file_id,
        node,
        parent_scope_id,
        null,
    );

    var it = fn_proto.iterate(&tree);
    while (it.next()) |param| {
        if (param.name_token) |name_token|
            _ = self.putDecl(
                gpa,
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
                gpa,
                tree,
                file_id,
                fn_scope_id,
                type_expr,
            );
    }

    if (fn_proto.ast.return_type.unwrap()) |return_type|
        self.walkNode(
            gpa,
            tree,
            file_id,
            fn_scope_id,
            return_type,
        );

    if (tree.nodeTag(node) == .fn_decl) {
        _, const block = tree.nodeData(node).node_and_node;
        self.walkNode(
            gpa,
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
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    parent_scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const block_scope_id = self.appendScope(
        gpa,
        file_id,
        node,
        parent_scope_id,
        null,
    );
    if (blockLabel(tree, node)) |label_token| {
        _ = self.putDecl(
            gpa,
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
            gpa,
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
                gpa,
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
                        gpa,
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
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    var it = ast.ChildIterator.init(tree, node);
    while (it.next(tree)) |child|
        self.walkNode(
            gpa,
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
fn fileDeclIterator(self: *const DeclStore, file_id: FileStore.FileId) FileDeclIterator {
    return .{
        .store = self,
        .file_id = file_id,
    };
}

const FileDeclIterator = struct {
    store: *const DeclStore,
    file_id: FileStore.FileId,
    index: usize = 0,

    pub fn next(self: *FileDeclIterator) ?DeclId {
        while (self.index < self.store.decls.len) {
            const index = self.index;
            self.index += 1;

            if (self.store.decls.items(.file_id)[index] == self.file_id)
                return .fromIndex(index);
        }
        return null;
    }
};

const std = @import("std");
const FileStore = @import("FileStore.zig");
const ModuleStore = @import("ModuleStore.zig");
const TypeStore = @import("TypeStore.zig");
const ast = @import("../ast.zig");
const files = @import("../files.zig");
const tracy = @import("tracy");
