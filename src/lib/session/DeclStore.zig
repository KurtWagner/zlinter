const DeclStore = @This();

// TODO: #149 - decide on error handling, specifically OOM. This module just panics to keep it simpler

decls: std.MultiArrayList(Decl),
scopes: std.MultiArrayList(Scope),

pub const empty: DeclStore = .{
    .decls = .empty,
    .scopes = .empty,
};

const DeclKind = enum {
    /// e.g., `const value = 1`, `fn run() void`, or a function parameter.
    declaration,
    /// e.g., `struct { value: u32 }` or `enum { value }`.
    field,
    /// e.g., `label: { ... }`.
    label,
};

const DeclType = enum {};

const Decl = struct {
    /// If unset, it's the root declaration.
    name_token: ?std.zig.Ast.TokenIndex,
    /// Token-only declarations, such as function parameters, do not have an
    /// owning AST node.
    ast_node: ?std.zig.Ast.Node.Index,
    file_id: FileStore.FileId,
    kind: DeclKind,

    /// Lazily evaluated when calling `declType()`
    resolved_type: ?Type = null,

    // TODO: #149 - just example of pattern to lookup things without duplicating, prob wont live here, places can call ast.* itself
    /// Returns the declaration visibility when it can be derived from the AST node.
    pub fn visibility(self: Decl, file_store: *const FileStore) ast.Visibility {
        const node = self.ast_node orelse return .private;
        const tree = file_store.fileTree(self.file_id);

        if (tree.fullVarDecl(node)) |var_decl| {
            return ast.varDeclVisibility(tree.*, var_decl);
        }

        var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
            return ast.fnProtoVisibility(tree.*, fn_proto);
        }

        return .private;
    }

    /// Lazily evaluates the type of a declaration
    pub fn declType(self: Decl) Type {
        if (self.resolved_type) |ty| return ty;

        // const ty = try resolveDeclType(decl_id);
        const ty: Type = .unknown;
        self.resolved_type = ty;
        return ty;
    }
};

const Scope = struct {
    parent_scope_id: ?ScopeId,
    owner_decl_id: ?DeclId,
    decl_by_name: std.StringHashMapUnmanaged(DeclId),
};

pub const Type = enum {
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

    pub fn name(self: Type) []const u8 {
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

const ScopeId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) ScopeId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: ScopeId) usize {
        return @intFromEnum(self);
    }
};

const DeclId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) DeclId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: DeclId) usize {
        return @intFromEnum(self);
    }
};

/// Stores declarations and lexical scopes for a parsed file.
pub fn store(
    self: *DeclStore,
    file_id: FileStore.FileId,
    file_store: *const FileStore,
    gpa: std.mem.Allocator,
) DeclId {
    const tree = file_store.fileTree(file_id);

    const root_decl_id = self.appendDecl(
        gpa,
        file_id,
        null,
        .root,
        .declaration,
    );

    const root_scope_id = self.appendScope(
        gpa,
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

/// Releases all declaration and scope storage owned by this store.
pub fn deinit(self: *DeclStore, gpa: std.mem.Allocator) void {
    for (self.scopes.items(.decl_by_name)) |*decl_by_name|
        decl_by_name.deinit(gpa);

    self.decls.deinit(gpa);
    self.scopes.deinit(gpa);
}

/// Appends a scope and returns its typed id.
fn appendScope(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    parent_scope_id: ?ScopeId,
    owner_decl_id: ?DeclId,
) ScopeId {
    const scope_id: ScopeId = .fromIndex(self.scopes.len);
    self.scopes.append(gpa, .{
        .parent_scope_id = parent_scope_id,
        .owner_decl_id = owner_decl_id,
        .decl_by_name = .empty,
    }) catch @panic("OOM");
    return scope_id;
}

/// Appends a declaration record and returns its typed id.
fn appendDecl(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    file_id: FileStore.FileId,
    name_token: ?std.zig.Ast.TokenIndex,
    ast_node: ?std.zig.Ast.Node.Index,
    kind: DeclKind,
) DeclId {
    const decl_id: DeclId = .fromIndex(self.decls.len);
    self.decls.append(gpa, .{
        .name_token = name_token,
        .ast_node = ast_node,
        .file_id = file_id,
        .kind = kind,
    }) catch @panic("OOM");
    return decl_id;
}

/// Inserts a named declaration into a scope unless the name is ignored or already present.
fn putDecl(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    tree: *const std.zig.Ast,
    file_id: FileStore.FileId,
    scope_id: ScopeId,
    name_token: std.zig.Ast.TokenIndex,
    ast_node: ?std.zig.Ast.Node.Index,
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
        kind,
    );
    self.putDeclId(gpa, scope_id, name, decl_id);
    return decl_id;
}

/// Extracts a declaration name from an AST node and inserts it into a scope.
fn putNodeDecl(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    tree: *const std.zig.Ast,
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
        declNameToken(tree, node) orelse return null,
        node,
        kind,
    );
}

/// Looks up a declaration by name directly within a scope.
fn scopeDecl(
    self: *const DeclStore,
    scope_id: ScopeId,
    name: []const u8,
) ?DeclId {
    return self.scopes.items(.decl_by_name)[scope_id.toIndex()].get(name);
}

/// Adds a declaration id to a scope's name map.
fn putDeclId(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    scope_id: ScopeId,
    name: []const u8,
    decl_id: DeclId,
) void {
    self.scopes.items(.decl_by_name)[scope_id.toIndex()].putNoClobber(
        gpa,
        name,
        decl_id,
    ) catch @panic("OOM");
}

/// Walks a node and dispatches to the handler that owns its scope semantics.
fn walkNode(
    self: *DeclStore,
    gpa: std.mem.Allocator,
    tree: *const std.zig.Ast,
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
    tree: *const std.zig.Ast,
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
                field.convertToNonTupleLike(tree);
                if (field.ast.tuple_like) continue;

                const name_token = field.ast.main_token;
                if (tree.tokenTag(name_token) == .identifier) {
                    _ = self.putDecl(gpa, tree, file_id, scope_id, name_token, member, .field);
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
    tree: *const std.zig.Ast,
    file_id: FileStore.FileId,
    parent_scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(&buffer, node).?;
    const fn_scope_id = self.appendScope(
        gpa,
        parent_scope_id,
        null,
    );

    var it = fn_proto.iterate(tree);
    while (it.next()) |param| {
        if (param.name_token) |name_token|
            _ = self.putDecl(
                gpa,
                tree,
                file_id,
                fn_scope_id,
                name_token,
                null,
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
    tree: *const std.zig.Ast,
    file_id: FileStore.FileId,
    parent_scope_id: ScopeId,
    node: std.zig.Ast.Node.Index,
) void {
    const block_scope_id = self.appendScope(
        gpa,
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
    tree: *const std.zig.Ast,
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

/// Returns the name token for a node declaration.
fn declNameToken(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.TokenIndex {
    return switch (tree.nodeTag(node)) {
        // Main token is name
        .container_field_init,
        .container_field_align,
        .container_field,
        => tree.nodeMainToken(node),
        // Main token is mutation (e.g., var or const)
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => tree.nodeMainToken(node) + 1,
        // Main token is "fn"
        .fn_decl,
        => tree.nodeMainToken(node) + 1,
        // Main token may be a name identifier
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            const token = tree.nodeMainToken(node) + 1;
            return switch (tree.tokenTag(token)) {
                .identifier => token,
                else => null,
            };
        },
        else => null,
    };
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
fn blockLabel(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.TokenIndex {
    const main_token = tree.nodeMainToken(node);
    if (main_token < 2) return null;
    if (tree.tokenTag(main_token - 1) != .colon) return null;
    if (tree.tokenTag(main_token - 2) != .identifier) return null;
    return main_token - 2;
}

const std = @import("std");
const FileStore = @import("FileStore.zig");
const ast = @import("../ast.zig");
