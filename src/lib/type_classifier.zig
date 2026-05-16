//! Lightweight AST-only type classification used by linter rules.

pub const TypeKind = session.LintContext.TypeKind;

pub fn classifyVarDecl(tree: Ast, var_decl: Ast.full.VarDecl) ?TypeKind {
    const name_token = var_decl.ast.mut_token + 1;
    const before_offset = tree.tokenStart(name_token);
    return classifyDeclLike(
        tree,
        var_decl.ast.type_node.unwrap(),
        var_decl.ast.init_node.unwrap(),
        before_offset,
        0,
    );
}

pub fn classifyContainerField(tree: Ast, field: Ast.full.ContainerField) ?TypeKind {
    const before_offset = tree.tokenStart(field.ast.main_token);
    return classifyDeclLike(
        tree,
        field.ast.type_expr.unwrap(),
        field.ast.value_expr.unwrap(),
        before_offset,
        0,
    );
}

pub fn classifyTypeNode(tree: Ast, node: Ast.Node.Index) ?TypeKind {
    const before_offset = tree.tokenStart(tree.firstToken(node));
    return classifyNodeForDeclType(tree, node, before_offset, 0);
}

fn classifyDeclLike(
    tree: Ast,
    maybe_type_node: ?Ast.Node.Index,
    maybe_value_node: ?Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?TypeKind {
    if (depth > 8) return .other;

    if (maybe_type_node) |type_node| {
        if (classifyNodeForDeclType(tree, type_node, before_offset, depth)) |kind| {
            if (kind != .other) return kind;
        }

        if (maybe_value_node == null) {
            const node = ast_helpers.unwrapNode(tree, type_node, .{});
            return if (tree.nodeTag(node) == .identifier and
                std.mem.eql(u8, tree.getNodeSource(node), "type"))
                .type
            else
                .other;
        }
    }

    if (maybe_value_node) |value_node| {
        return classifyNodeForValue(tree, value_node, before_offset, depth);
    }

    return null;
}

fn classifyNodeForDeclType(
    tree: Ast,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?TypeKind {
    const unwrapped = ast_helpers.unwrapNode(tree, node, .{});

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, unwrapped)) |fn_proto| {
        return classifyFnProto(fn_proto, tree, .decl_type, before_offset, depth + 1);
    }

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, unwrapped)) |container_decl| {
        return switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
            .keyword_struct => if (ast_helpers.isContainerNamespace(tree, container_decl)) null else .struct_instance,
            .keyword_union => .union_instance,
            .keyword_opaque => .opaque_instance,
            .keyword_enum => .enum_instance,
            else => .other,
        };
    }

    if (tree.nodeTag(unwrapped) == .identifier) {
        const ident = tree.getNodeSource(unwrapped);
        if (std.mem.eql(u8, ident, "type")) return .type;
    }

    return .other;
}

fn classifyNodeForValue(
    tree: Ast,
    value_node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?TypeKind {
    const node = ast_helpers.unwrapNode(tree, value_node, .{});

    if (depth > 8) return .other;

    if (tree.nodeTag(node) == .identifier) {
        if (classifyIdentifierOrBuiltin(tree, node, before_offset, depth + 1)) |kind| {
            if (kind != .other) {
                if (kind == .fn_type) return .@"fn";
                if (kind == .fn_type_returns_type) return .fn_returns_type;
                return kind;
            }
        }

        const ident = tree.getNodeSource(node);
        if (isPrimitiveTypeName(ident)) return .type;
    }

    if (tree.nodeTag(node) == .address_of) {
        const target_node = tree.nodeData(node).node;
        const target_unwrapped = ast_helpers.unwrapNode(tree, target_node, .{});
        var fn_proto_buffer_addr_of: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_proto_buffer_addr_of, target_unwrapped)) |fn_proto| {
            return classifyFnProto(fn_proto, tree, .decl_type, before_offset, depth + 1);
        }

        if (tree.nodeTag(target_unwrapped) == .identifier) {
            if (classifyIdentifierOrBuiltin(tree, target_unwrapped, before_offset, depth + 1)) |kind| {
                return switch (kind) {
                    .fn_type => .@"fn",
                    .fn_type_returns_type => .fn_returns_type,
                    .@"fn", .fn_returns_type => kind,
                    else => .other,
                };
            }
        }
    }

    var struct_init_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
        if (struct_init.ast.type_expr.unwrap()) |init_type_expr| {
            const init_type = ast_helpers.unwrapNode(tree, init_type_expr, .{});

            var fn_proto_from_init_buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&fn_proto_from_init_buffer, init_type)) |fn_proto| {
                return classifyFnProto(fn_proto, tree, .decl_type, before_offset, depth + 1);
            }

            if (tree.nodeTag(init_type) == .identifier) {
                if (classifyIdentifierOrBuiltin(tree, init_type, before_offset, depth + 1)) |kind| {
                    return switch (kind) {
                        .namespace_type => null,
                        .struct_type => .struct_instance,
                        .union_type => .union_instance,
                        .enum_type => .enum_instance,
                        .opaque_type => .opaque_instance,
                        .type => .other,
                        else => kind,
                    };
                }
            }
        }
    }

    switch (tree.nodeTag(node)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            const name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, name, "@Type") or
                std.mem.eql(u8, name, "@TypeOf") or
                std.mem.eql(u8, name, "@This"))
            {
                return .type;
            }
        },
        .error_set_decl, .merge_error_sets => return .error_type,
        else => {},
    }

    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        if (classifyCalledExpression(tree, call.ast.fn_expr, before_offset, depth + 1)) |kind| {
            return kind;
        }
    }

    if (isTypeInfoBackedTypeExpr(tree, node, depth + 1)) return .type;

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
        return switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
            .keyword_struct => if (ast_helpers.isContainerNamespace(tree, container_decl)) .namespace_type else .struct_type,
            .keyword_union => .union_type,
            .keyword_opaque => .opaque_type,
            .keyword_enum => .enum_type,
            else => .other,
        };
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return classifyFnProto(fn_proto, tree, .value_expr, before_offset, depth + 1);
    }

    return .other;
}

fn classifyCalledExpression(
    tree: Ast,
    fn_expr_node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?TypeKind {
    const fn_expr = ast_helpers.unwrapNode(tree, fn_expr_node, .{});
    switch (tree.nodeTag(fn_expr)) {
        .identifier => {
            const kind = classifyIdentifierOrBuiltin(tree, fn_expr, before_offset, depth + 1) orelse return null;
            return switch (kind) {
                .fn_returns_type => .type,
                .fn_type_returns_type => .type,
                else => null,
            };
        },
        .field_access => {
            const call_name_token = tree.nodeData(fn_expr).node_and_token.@"1";
            if (looksLikeTypeFactoryName(tree.tokenSlice(call_name_token))) return .type;
            return null;
        },
        else => return null,
    }
}

fn looksLikeTypeFactoryName(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

fn isTypeInfoBackedTypeExpr(
    tree: Ast,
    node: Ast.Node.Index,
    depth: u8,
) bool {
    if (depth > 8) return false;

    const unwrapped = ast_helpers.unwrapNode(tree, node, .{});
    switch (tree.nodeTag(unwrapped)) {
        .field_access => {
            const base_node = tree.nodeData(unwrapped).node_and_token.@"0";
            const field_name_token = tree.nodeData(unwrapped).node_and_token.@"1";
            if (std.mem.eql(u8, tree.tokenSlice(field_name_token), "backing_integer")) {
                return containsTypeInfoCall(tree, base_node, depth + 1);
            }
            return isTypeInfoBackedTypeExpr(tree, base_node, depth + 1);
        },
        else => return false,
    }
}

fn containsTypeInfoCall(
    tree: Ast,
    node: Ast.Node.Index,
    depth: u8,
) bool {
    if (depth > 8) return false;
    const unwrapped = ast_helpers.unwrapNode(tree, node, .{});

    switch (tree.nodeTag(unwrapped)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(unwrapped)), "@typeInfo");
        },
        .field_access => return containsTypeInfoCall(tree, tree.nodeData(unwrapped).node_and_token.@"0", depth + 1),
        else => return false,
    }
}

fn classifyIdentifierOrBuiltin(
    tree: Ast,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?TypeKind {
    if (tree.nodeTag(node) != .identifier) return null;
    const ident = tree.getNodeSource(node);
    if (std.mem.eql(u8, ident, "type")) return .type;

    if (depth > 8) return .other;

    if (findVarDeclByNameBefore(tree, ident, before_offset)) |var_decl| {
        return classifyVarDeclAtDepth(tree, var_decl, before_offset, depth + 1);
    }

    if (findFnProtoByNameBefore(tree, ident, before_offset)) |fn_proto| {
        return classifyFnProto(fn_proto, tree, .decl_type, before_offset, depth + 1);
    }

    return .other;
}

fn isPrimitiveTypeName(ident: []const u8) bool {
    inline for (&.{
        "void",
        "bool",
        "noreturn",
        "anyopaque",
        "usize",
        "isize",
        "u8",
        "u16",
        "u32",
        "u64",
        "u128",
        "i8",
        "i16",
        "i32",
        "i64",
        "i128",
        "f16",
        "f32",
        "f64",
        "f80",
        "f128",
        "c_short",
        "c_ushort",
        "c_int",
        "c_uint",
        "c_long",
        "c_ulong",
        "c_longdouble",
        "c_longlong",
        "c_ulonglong",
        "c_char",
    }) |name| {
        if (std.mem.eql(u8, ident, name)) return true;
    }
    return false;
}

const FnProtoContext = enum { decl_type, value_expr };

fn classifyFnProto(
    fn_proto: Ast.full.FnProto,
    tree: Ast,
    context: FnProtoContext,
    before_offset: Ast.ByteOffset,
    depth: u8,
) TypeKind {
    const return_node = fn_proto.ast.return_type.unwrap() orelse {
        return switch (context) {
            .decl_type => .@"fn",
            .value_expr => .fn_type,
        };
    };

    const return_unwrapped = ast_helpers.unwrapNode(tree, return_node, .{});
    if (tree.nodeTag(return_unwrapped) == .identifier) {
        const ident = tree.getNodeSource(return_unwrapped);
        if (isPrimitiveTypeName(ident)) {
            return switch (context) {
                .decl_type => .@"fn",
                .value_expr => .fn_type,
            };
        }
    }

    const maybe_kind = classifyIdentifierOrBuiltin(tree, return_unwrapped, before_offset, depth + 1);
    const returns_type = maybe_kind == .type;

    return switch (context) {
        .decl_type => if (returns_type) .fn_returns_type else .@"fn",
        .value_expr => if (returns_type) .fn_type_returns_type else .fn_type,
    };
}

fn classifyVarDeclAtDepth(
    tree: Ast,
    var_decl: Ast.full.VarDecl,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?TypeKind {
    if (depth > 8) return .other;
    return classifyDeclLike(
        tree,
        var_decl.ast.type_node.unwrap(),
        var_decl.ast.init_node.unwrap(),
        before_offset,
        depth + 1,
    );
}

fn findVarDeclByNameBefore(
    tree: Ast,
    name: []const u8,
    before_offset: Ast.ByteOffset,
) ?Ast.full.VarDecl {
    var best_offset: ?Ast.ByteOffset = null;
    var best_decl: ?Ast.full.VarDecl = null;
    var nearest_after_offset: ?Ast.ByteOffset = null;
    var nearest_after_decl: ?Ast.full.VarDecl = null;

    var index: u32 = 1;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const var_decl = tree.fullVarDecl(node) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

        const offset = tree.tokenStart(name_token);
        if (offset < before_offset) {
            if (best_offset == null or offset > best_offset.?) {
                best_offset = offset;
                best_decl = var_decl;
            }
        } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
            nearest_after_offset = offset;
            nearest_after_decl = var_decl;
        }
    }

    return best_decl orelse nearest_after_decl;
}

fn findFnProtoByNameBefore(
    tree: Ast,
    name: []const u8,
    before_offset: Ast.ByteOffset,
) ?Ast.full.FnProto {
    var best_offset: ?Ast.ByteOffset = null;
    var best_decl: ?Ast.full.FnProto = null;
    var nearest_after_offset: ?Ast.ByteOffset = null;
    var nearest_after_decl: ?Ast.full.FnProto = null;

    var index: u32 = 1;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        var buffer: [1]Ast.Node.Index = undefined;
        const fn_proto = switch (tree.nodeTag(node)) {
            .fn_proto => tree.fnProto(node),
            .fn_proto_multi => tree.fnProtoMulti(node),
            .fn_proto_one => tree.fnProtoOne(&buffer, node),
            .fn_proto_simple => tree.fnProtoSimple(&buffer, node),
            .fn_decl => tree.fullFnProto(&buffer, node),
            else => null,
        } orelse continue;

        const name_token = fn_proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

        const offset = tree.tokenStart(name_token);
        if (offset < before_offset) {
            if (best_offset == null or offset > best_offset.?) {
                best_offset = offset;
                best_decl = fn_proto;
            }
        } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
            nearest_after_offset = offset;
            nearest_after_decl = fn_proto;
        }
    }

    return best_decl orelse nearest_after_decl;
}

const std = @import("std");
const ast_helpers = @import("ast.zig");
const session = @import("session.zig");
const Ast = std.zig.Ast;

test {
    std.testing.refAllDecls(@This());
}
