//! Shared cross-file semantic resolver used by rules that need lightweight
//! declaration/container/import traversal.

pub const Resolver = struct {
    const Self = @This();

    context: *session.LintContext,
    doc: *const session.LintDocument,
    gpa: std.mem.Allocator,
    file_cache: std.ArrayList(FileContext),

    const FileContext = struct {
        handle: *session.Handle,
        abs_path: []const u8,
        tree: Ast,
        decl_index: *const semantic.DeclIndex,
    };

    pub const DeclRef = struct {
        file_index: usize,
        node: Ast.Node.Index,
    };

    pub const ContainerRef = struct {
        file_index: usize,
        node: Ast.Node.Index,
    };

    pub const ResolvedRef = union(enum) {
        decl: DeclRef,
        container: ContainerRef,
        module: usize, // file index
    };

    pub fn init(
        context: *session.LintContext,
        doc: *const session.LintDocument,
        gpa: std.mem.Allocator,
    ) !Self {
        var self = Self{
            .context = context,
            .doc = doc,
            .gpa = gpa,
            .file_cache = .empty,
        };
        errdefer self.deinit(gpa);

        try self.file_cache.append(gpa, .{
            .handle = doc.handle,
            .abs_path = doc.handle.abs_path,
            .tree = doc.handle.tree,
            .decl_index = &doc.handle.decl_index,
        });

        return self;
    }

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        self.file_cache.deinit(gpa);
    }

    pub fn resolveExpr(
        self: *Self,
        doc: *const session.LintDocument,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ResolvedRef {
        if (depth > 16) return null;
        const tree = doc.handle.tree;
        const unwrapped = ast_helpers.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });

        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                if (semantic.resolveParamTypeNode(tree, doc.lineage, unwrapped, name)) |type_node| {
                    if (self.resolveTypeExprToContainer(doc, type_node, before_offset, depth + 1)) |container| {
                        return .{ .container = container };
                    }
                }

                if (self.lookupDeclByNameNear(0, name, before_offset)) |decl| {
                    return self.resolveDeclOrAlias(decl, depth + 1);
                }
                return null;
            },
            .field_access => {
                const data = tree.nodeData(unwrapped).node_and_token;
                const lhs = data.@"0";
                const field_token = data.@"1";
                if (tree.tokenTag(field_token) != .identifier) return null;

                const field_name = tree.tokenSlice(field_token);
                const lhs_resolved = self.resolveExpr(doc, lhs, before_offset, depth + 1) orelse return null;
                return self.resolveFieldOnResolved(lhs_resolved, field_name, before_offset, depth + 1);
            },
            else => return null,
        }
    }

    pub fn resolveEnumContainerForLiteral(
        self: *Self,
        doc: *const session.LintDocument,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        const tree = doc.handle.tree;

        var current = node;
        while (doc.lineage.items(.parent)[@intFromEnum(current)]) |parent| {
            current = parent;

            if (tree.fullVarDecl(current)) |var_decl| {
                const type_node = var_decl.ast.type_node.unwrap() orelse return null;
                const container = self.resolveTypeExprToContainer(doc, type_node, before_offset, depth + 1) orelse return null;
                if (self.isEnumContainer(container)) return container;
                return null;
            }

            if (tree.fullContainerField(current)) |field| {
                const type_node = field.ast.type_expr.unwrap() orelse return null;
                const container = self.resolveTypeExprToContainer(doc, type_node, before_offset, depth + 1) orelse return null;
                if (self.isEnumContainer(container)) return container;
                return null;
            }

            var struct_init_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&struct_init_buffer, current)) |struct_init| {
                const field_name = inferStructInitFieldName(tree, struct_init, node) orelse return null;
                const init_type_node = struct_init.ast.type_expr.unwrap() orelse return null;
                const init_container = self.resolveTypeExprToContainer(doc, init_type_node, before_offset, depth + 1) orelse return null;

                const member = self.resolveContainerMember(init_container, field_name) orelse return null;
                const member_container = self.resolveContainerFromDecl(member, before_offset, depth + 1) orelse return null;
                if (self.isEnumContainer(member_container)) return member_container;
                return null;
            }
        }

        return null;
    }

    pub fn resolveContainerMember(self: *Self, container: ContainerRef, member_name: []const u8) ?DeclRef {
        const file = self.file_cache.items[container.file_index];
        const tree = file.tree;

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        const full = tree.fullContainerDecl(&container_decl_buffer, container.node) orelse return null;

        for (full.ast.members) |member| {
            switch (tree.nodeTag(member)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    const token = tree.nodeMainToken(member);
                    if (std.mem.eql(u8, tree.tokenSlice(token), member_name)) {
                        return .{ .file_index = container.file_index, .node = member };
                    }
                },
                .fn_decl => {
                    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
                    const fn_decl = ast_helpers.fnDecl(tree, member, &fn_proto_buffer) orelse continue;
                    const name_token = fn_decl.proto.name_token orelse continue;
                    if (std.mem.eql(u8, tree.tokenSlice(name_token), member_name)) {
                        return .{ .file_index = container.file_index, .node = member };
                    }
                },
                .simple_var_decl,
                .local_var_decl,
                .global_var_decl,
                .aligned_var_decl,
                => {
                    const var_decl = tree.fullVarDecl(member).?;
                    const name_token = var_decl.ast.mut_token + 1;
                    if (std.mem.eql(u8, tree.tokenSlice(name_token), member_name)) {
                        return .{ .file_index = container.file_index, .node = member };
                    }
                },
                else => {},
            }
        }

        return null;
    }

    pub fn resolveContainerForResolved(
        self: *Self,
        resolved: ResolvedRef,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        return switch (resolved) {
            .container => |container| container,
            .decl => |decl| self.resolveContainerFromDecl(decl, before_offset, depth + 1),
            .module => null,
        };
    }

    pub fn docCommentTextForResolved(self: *Self, resolved: ResolvedRef) ?[]const u8 {
        return switch (resolved) {
            .decl => |decl| self.docCommentTextForDecl(decl),
            .container => |container| self.docCommentTextForDecl(.{ .file_index = container.file_index, .node = container.node }),
            .module => null,
        };
    }

    pub fn docCommentTextForDecl(self: *Self, decl: DeclRef) ?[]const u8 {
        const file = self.file_cache.items[decl.file_index];
        return docCommentTextFromNode(file.tree, decl.node, self.gpa) catch null;
    }

    pub fn lookupTopLevelDecl(self: *Self, file_index: usize, name: []const u8) ?DeclRef {
        const file = self.file_cache.items[file_index];
        const tree = file.tree;

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        for (tree.rootDecls()) |decl| {
            if (tree.fullVarDecl(decl)) |var_decl| {
                const name_token = var_decl.ast.mut_token + 1;
                if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) {
                    return .{ .file_index = file_index, .node = decl };
                }
            } else if (ast_helpers.fnDecl(tree, decl, &fn_proto_buffer)) |fn_decl| {
                const name_token = fn_decl.proto.name_token orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) {
                    return .{ .file_index = file_index, .node = decl };
                }
            }
        }

        return null;
    }

    pub fn lookupDeclByNameNear(
        self: *Self,
        file_index: usize,
        name: []const u8,
        before_offset: Ast.ByteOffset,
    ) ?DeclRef {
        const file = self.file_cache.items[file_index];
        const var_hit = file.decl_index.findVarDeclHitNear(name, before_offset);
        const fn_hit = file.decl_index.findFnDeclHitNear(name, before_offset);
        const hit = pickBestDeclHit(var_hit, fn_hit, before_offset) orelse return null;
        return .{ .file_index = file_index, .node = hit.node };
    }

    fn resolveDeclOrAlias(self: *Self, decl: DeclRef, depth: u8) ?ResolvedRef {
        if (depth > 16) return null;
        const file = self.file_cache.items[decl.file_index];
        const tree = file.tree;

        if (tree.fullVarDecl(decl.node)) |var_decl| {
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (self.resolveImportFromInit(decl.file_index, init_node)) |import_file_index| {
                    return .{ .module = import_file_index };
                }
            }
            return .{ .decl = decl };
        }

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_proto_buffer, decl.node)) |_| {
            return .{ .decl = decl };
        }

        var container_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_buffer, decl.node)) |_| {
            return .{ .container = .{ .file_index = decl.file_index, .node = decl.node } };
        }

        return .{ .decl = decl };
    }

    fn resolveExprInFile(self: *Self, file_index: usize, node: Ast.Node.Index, before_offset: Ast.ByteOffset, depth: u8) ?ResolvedRef {
        const file = self.file_cache.items[file_index];
        if (file_index == 0) return self.resolveExpr(self.doc, node, before_offset, depth);
        if (depth > 16) return null;
        const tree = file.tree;
        const unwrapped = ast_helpers.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });
        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                if (self.lookupDeclByNameNear(file_index, name, before_offset)) |decl| {
                    return self.resolveDeclOrAlias(decl, depth + 1);
                }
                return null;
            },
            .field_access => {
                const data = tree.nodeData(unwrapped).node_and_token;
                const lhs = data.@"0";
                const field_token = data.@"1";
                if (tree.tokenTag(field_token) != .identifier) return null;
                const field_name = tree.tokenSlice(field_token);
                const lhs_resolved = self.resolveExprInFile(file_index, lhs, before_offset, depth + 1) orelse return null;
                return self.resolveFieldOnResolved(lhs_resolved, field_name, before_offset, depth + 1);
            },
            else => return null,
        }
    }

    fn resolveFieldOnResolved(
        self: *Self,
        resolved: ResolvedRef,
        field_name: []const u8,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ResolvedRef {
        if (depth > 16) return null;
        switch (resolved) {
            .module => |file_index| {
                const decl = self.lookupTopLevelDecl(file_index, field_name) orelse return null;
                return self.resolveDeclOrAlias(decl, depth + 1);
            },
            .container => |container| {
                const member = self.resolveContainerMember(container, field_name) orelse return null;
                return self.resolveDeclOrAlias(member, depth + 1);
            },
            .decl => |decl| {
                if (self.resolveVarInitResolved(decl, depth + 1)) |target| {
                    const member = self.resolveFieldOnResolved(target, field_name, before_offset, depth + 1) orelse return null;
                    return member;
                }
                if (self.resolveContainerFromDecl(decl, before_offset, depth + 1)) |container| {
                    const member = self.resolveContainerMember(container, field_name) orelse return null;
                    return self.resolveDeclOrAlias(member, depth + 1);
                }
                return null;
            },
        }
    }

    fn resolveContainerFromDecl(self: *Self, decl: DeclRef, before_offset: Ast.ByteOffset, depth: u8) ?ContainerRef {
        if (depth > 16) return null;
        const file = self.file_cache.items[decl.file_index];
        const tree = file.tree;

        if (tree.fullContainerField(decl.node)) |field| {
            const type_node = field.ast.type_expr.unwrap() orelse return null;
            return self.resolveTypeExprInFile(decl.file_index, type_node, before_offset, depth + 1);
        }

        if (tree.fullVarDecl(decl.node)) |var_decl| {
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                if (self.resolveTypeExprInFile(decl.file_index, type_node, before_offset, depth + 1)) |container| {
                    return container;
                }
            }
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                var struct_init_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&struct_init_buffer, init_node)) |struct_init| {
                    if (struct_init.ast.type_expr.unwrap()) |type_expr| {
                        if (self.resolveTypeExprInFile(decl.file_index, type_expr, before_offset, depth + 1)) |container| {
                            return container;
                        }
                    }
                }
                if (self.resolveContainerFromNode(decl.file_index, init_node, before_offset, depth + 1)) |container| {
                    return container;
                }
            }
        }

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_decl_buffer, decl.node)) |_| {
            return .{ .file_index = decl.file_index, .node = decl.node };
        }

        return null;
    }

    fn resolveVarInitResolved(self: *Self, decl: DeclRef, depth: u8) ?ResolvedRef {
        if (depth > 16) return null;
        const file = self.file_cache.items[decl.file_index];
        const tree = file.tree;
        const var_decl = tree.fullVarDecl(decl.node) orelse return null;
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;

        if (self.resolveImportFromInit(decl.file_index, init_node)) |import_file_index| {
            return .{ .module = import_file_index };
        }

        const init_offset = tree.tokenStart(tree.firstToken(init_node));
        const resolved = self.resolveExprInFile(decl.file_index, init_node, init_offset, depth + 1) orelse return null;
        return switch (resolved) {
            .module, .container => resolved,
            .decl => null,
        };
    }

    fn resolveContainerFromNode(
        self: *Self,
        file_index: usize,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        const tree = self.file_cache.items[file_index].tree;
        const unwrapped = ast_helpers.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });

        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, unwrapped)) |_| {
            return .{ .file_index = file_index, .node = unwrapped };
        }

        if (self.resolveTypeExprInFile(file_index, unwrapped, before_offset, depth + 1)) |container| {
            return container;
        }

        return null;
    }

    fn resolveTypeExprToContainer(
        self: *Self,
        _: *const session.LintDocument,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        return self.resolveTypeExprInFile(0, node, before_offset, depth);
    }

    fn resolveTypeExprInFile(
        self: *Self,
        file_index: usize,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        const tree = self.file_cache.items[file_index].tree;
        const unwrapped = ast_helpers.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_decl_buffer, unwrapped)) |_| {
            return .{ .file_index = file_index, .node = unwrapped };
        }

        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                const decl = self.lookupDeclByNameNear(file_index, name, before_offset) orelse return null;
                return self.resolveContainerFromDecl(decl, before_offset, depth + 1);
            },
            .field_access => {
                const data = tree.nodeData(unwrapped).node_and_token;
                const lhs = data.@"0";
                const field_token = data.@"1";
                if (tree.tokenTag(field_token) != .identifier) return null;
                const field_name = tree.tokenSlice(field_token);

                const lhs_resolved = self.resolveExprInFile(file_index, lhs, before_offset, depth + 1) orelse return null;
                const rhs_resolved = self.resolveFieldOnResolved(lhs_resolved, field_name, before_offset, depth + 1) orelse return null;
                return switch (rhs_resolved) {
                    .container => |container| container,
                    .decl => |decl| self.resolveContainerFromDecl(decl, before_offset, depth + 1),
                    .module => null,
                };
            },
            else => return null,
        }
    }

    fn isEnumContainer(self: *Self, container: ContainerRef) bool {
        const file = self.file_cache.items[container.file_index];
        var buffer: [2]Ast.Node.Index = undefined;
        const full = file.tree.fullContainerDecl(&buffer, container.node) orelse return false;
        return file.tree.tokens.items(.tag)[full.ast.main_token] == .keyword_enum;
    }

    fn resolveImportFromInit(self: *Self, file_index: usize, init_node: Ast.Node.Index) ?usize {
        const file = self.file_cache.items[file_index];
        const tree = file.tree;

        const import_path = ast_helpers.importPath(tree, init_node) orelse return null;
        const handle = self.context.resolveImportHandle(
            file.abs_path,
            import_path,
        ) catch return null;
        const import_handle = handle orelse return null;

        return self.getOrLoadFileByHandle(import_handle) catch null;
    }

    fn getOrLoadFileByHandle(self: *Self, handle: *session.Handle) !usize {
        for (self.file_cache.items, 0..) |file, i| {
            if (std.mem.eql(u8, file.abs_path, handle.abs_path)) return i;
        }

        try self.file_cache.append(self.gpa, .{
            .handle = handle,
            .abs_path = handle.abs_path,
            .tree = handle.tree,
            .decl_index = &handle.decl_index,
        });
        return self.file_cache.items.len - 1;
    }
};

fn pickBestDeclHit(
    var_hit: ?semantic.DeclHit,
    fn_hit: ?semantic.DeclHit,
    before_offset: Ast.ByteOffset,
) ?semantic.DeclHit {
    if (var_hit == null) return fn_hit;
    if (fn_hit == null) return var_hit;

    const lhs = var_hit.?;
    const rhs = fn_hit.?;

    const lhs_before = lhs.offset < before_offset;
    const rhs_before = rhs.offset < before_offset;

    if (lhs_before and !rhs_before) return lhs;
    if (!lhs_before and rhs_before) return rhs;
    if (lhs_before and rhs_before) {
        return if (lhs.offset >= rhs.offset) lhs else rhs;
    }
    return if (lhs.offset <= rhs.offset) lhs else rhs;
}

pub fn docCommentTextFromNode(tree: Ast, node: Ast.Node.Index, gpa: std.mem.Allocator) !?[]const u8 {
    const first_token = tree.firstToken(node);
    if (first_token == 0) return null;

    const token = first_token - 1;
    const is_doc = switch (tree.tokenTag(token)) {
        .doc_comment, .container_doc_comment => true,
        else => false,
    };
    if (!is_doc) return null;

    var start = token;
    while (start > 0) : (start -= 1) {
        const prev = start - 1;
        switch (tree.tokenTag(prev)) {
            .doc_comment, .container_doc_comment => {},
            else => break,
        }
    }

    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    var i = start;
    while (i <= token) : (i += 1) {
        const slice = tree.tokenSlice(i);
        const body = switch (tree.tokenTag(i)) {
            .doc_comment => if (slice.len >= 3) slice[3..] else slice,
            .container_doc_comment => if (slice.len >= 3) slice[3..] else slice,
            else => slice,
        };
        try aw.writer.writeAll(body);
        try aw.writer.writeByte('\n');
    }

    return try aw.toOwnedSlice();
}

fn inferStructInitFieldName(
    tree: Ast,
    struct_init: Ast.full.StructInit,
    value_node: Ast.Node.Index,
) ?[]const u8 {
    for (struct_init.ast.fields) |field_node| {
        if (field_node != value_node) continue;

        const first = tree.firstToken(field_node);
        if (first < 3) return null;
        if (tree.tokenTag(first - 1) != .equal) return null;
        if (tree.tokenTag(first - 2) != .identifier) return null;
        if (tree.tokenTag(first - 3) != .period) return null;
        return tree.tokenSlice(first - 2);
    }
    return null;
}

const std = @import("std");
const Ast = std.zig.Ast;
const ast_helpers = @import("ast.zig");
const semantic = @import("semantic.zig");
const session = @import("session.zig");

test {
    std.testing.refAllDecls(@This());
}
