//! Shared semantic helpers and import resolution context for rules.

pub const SemanticContext = struct {
    build_info: ?*const BuildInfo = null,

    pub fn init(build_info: ?*const BuildInfo) SemanticContext {
        return .{ .build_info = build_info };
    }

    pub fn setBuildInfo(self: *SemanticContext, build_info: *const BuildInfo) void {
        self.build_info = build_info;
    }

    /// Resolves an import path from an importer file.
    ///
    /// Resolution order:
    /// 1. relative imports (`./`, `../`)
    /// 2. build-provided module map (`BuildInfo.module_imports`)
    pub fn resolveImportPathAlloc(
        self: *const SemanticContext,
        importer_abs_path: []const u8,
        import_path: []const u8,
        gpa: std.mem.Allocator,
    ) ?[]const u8 {
        if (std.mem.startsWith(u8, import_path, "./") or std.mem.startsWith(u8, import_path, "../")) {
            const importer_dir = std.fs.path.dirname(importer_abs_path) orelse return null;
            return std.fs.path.resolve(gpa, &.{ importer_dir, import_path }) catch null;
        }

        if (self.build_info) |build_info| {
            if (build_info.module_imports) |module_imports| {
                // Prefer scoped entries where available.
                const scope_id = scopeFromImporter(importer_abs_path, build_info.module_roots);

                if (scope_id) |scope| {
                    for (module_imports) |entry| {
                        if (entry.scope_id) |entry_scope| {
                            if (!std.mem.eql(u8, entry_scope, scope)) continue;
                            if (std.mem.eql(u8, entry.import_name, import_path)) {
                                return gpa.dupe(u8, entry.root_source_path) catch null;
                            }
                        }
                    }
                }

                // Fallback to unscoped/global mapping.
                for (module_imports) |entry| {
                    if (entry.scope_id != null) continue;
                    if (std.mem.eql(u8, entry.import_name, import_path)) {
                        return gpa.dupe(u8, entry.root_source_path) catch null;
                    }
                }
            }
        }

        return null;
    }
};

fn scopeFromImporter(
    importer_abs_path: []const u8,
    module_roots: ?[]const BuildInfo.ModuleRootEntry,
) ?[]const u8 {
    const roots = module_roots orelse return null;

    var best_len: usize = 0;
    var best_scope: ?[]const u8 = null;

    for (roots) |entry| {
        if (!std.mem.startsWith(u8, importer_abs_path, entry.root_dir_path)) continue;
        if (entry.root_dir_path.len < best_len) continue;
        best_len = entry.root_dir_path.len;
        best_scope = entry.scope_id;
    }

    return best_scope;
}

pub fn findVarDeclByNameNear(
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

pub fn findVarDeclByNameBefore(
    tree: Ast,
    name: []const u8,
    before_offset: Ast.ByteOffset,
) ?Ast.full.VarDecl {
    return findVarDeclByNameNear(tree, name, before_offset);
}

pub fn findFnDeclByNameNear(
    tree: Ast,
    name: []const u8,
    before_offset: Ast.ByteOffset,
) ?Ast.full.FnProto {
    var best_offset: ?Ast.ByteOffset = null;
    var best_fn: ?Ast.full.FnProto = null;
    var nearest_after_offset: ?Ast.ByteOffset = null;
    var nearest_after_fn: ?Ast.full.FnProto = null;

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    var index: u32 = 1;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const fn_decl = ast_helpers.fnDecl(tree, node, &fn_proto_buffer) orelse continue;

        const name_token = fn_decl.proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

        const offset = tree.tokenStart(name_token);
        if (offset < before_offset) {
            if (best_offset == null or offset > best_offset.?) {
                best_offset = offset;
                best_fn = fn_decl.proto;
            }
        } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
            nearest_after_offset = offset;
            nearest_after_fn = fn_decl.proto;
        }
    }

    return best_fn orelse nearest_after_fn;
}

pub fn resolveParamTypeNode(
    tree: Ast,
    lineage: ast_helpers.NodeLineage,
    node: Ast.Node.Index,
    param_name: []const u8,
) ?Ast.Node.Index {
    var current = node;

    while (lineage.items(.parent)[@intFromEnum(current)]) |parent| {
        current = parent;
        if (tree.nodeTag(current) != .fn_decl) continue;

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        const fn_decl = ast_helpers.fnDecl(tree, current, &fn_proto_buffer) orelse continue;
        var param_it = fn_decl.proto.iterate(&tree);
        while (param_it.next()) |param| {
            const name_token = param.name_token orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(name_token), param_name)) continue;
            return param.type_expr;
        }
        return null;
    }

    return null;
}

pub fn isStdImportExpr(
    tree: Ast,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    if (depth > 12) return false;

    const unwrapped = ast_helpers.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            const ident = tree.getNodeSource(unwrapped);
            const var_decl = findVarDeclByNameNear(tree, ident, before_offset) orelse return false;
            const init_node = var_decl.ast.init_node.unwrap() orelse return false;
            return isStdImportExpr(tree, init_node, before_offset, depth + 1);
        },
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const main_token = tree.nodeMainToken(unwrapped);
            if (!std.mem.eql(u8, "@import", tree.tokenSlice(main_token))) return false;
            const data = tree.nodeData(unwrapped);
            const arg_node = data.opt_node_and_opt_node[0].unwrap() orelse return false;
            if (tree.nodeTag(arg_node) != .string_literal) return false;

            const import_slice = tree.tokenSlice(tree.nodeMainToken(arg_node));
            return import_slice.len >= 2 and std.mem.eql(u8, import_slice[1 .. import_slice.len - 1], "std");
        },
        else => return false,
    }
}

pub fn isRootContainerExpr(
    tree: Ast,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    if (depth > 8) return false;
    const unwrapped = ast_helpers.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });

    switch (tree.nodeTag(unwrapped)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => return std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(unwrapped)), "@This"),
        .identifier => {
            const ident = tree.getNodeSource(unwrapped);
            const var_decl = findVarDeclByNameBefore(tree, ident, before_offset) orelse return false;
            const init_node = var_decl.ast.init_node.unwrap() orelse return false;
            return isRootContainerExpr(tree, init_node, before_offset, depth + 1);
        },
        else => return false,
    }
}

const std = @import("std");
const Ast = std.zig.Ast;
const BuildInfo = @import("BuildInfo.zig");
const ast_helpers = @import("ast.zig");

test {
    std.testing.refAllDecls(@This());
}

test "SemanticContext.resolveImportPathAlloc resolves relative imports" {
    var gpa = std.testing.allocator;
    const ctx = SemanticContext.init(null);
    const resolved = ctx.resolveImportPathAlloc(
        "/repo/src/main.zig",
        "./foo.zig",
        gpa,
    ) orelse return error.TestUnexpectedResult;
    defer gpa.free(resolved);

    try std.testing.expectEqualStrings("/repo/src/foo.zig", resolved);
}

test "SemanticContext.resolveImportPathAlloc resolves scoped module imports" {
    var gpa = std.testing.allocator;

    const module_roots = [_]BuildInfo.ModuleRootEntry{
        .{ .scope_id = "/repo/app/src/root.zig", .root_dir_path = "/repo/app/src" },
    };
    const module_imports = [_]BuildInfo.ModuleImportEntry{
        .{
            .scope_id = "/repo/app/src/root.zig",
            .import_name = "shared_mod",
            .root_source_path = "/repo/shared/mod.zig",
        },
    };
    const build_info = BuildInfo{
        .module_roots = &module_roots,
        .module_imports = &module_imports,
    };
    const ctx = SemanticContext.init(&build_info);

    const resolved = ctx.resolveImportPathAlloc(
        "/repo/app/src/feature/file.zig",
        "shared_mod",
        gpa,
    ) orelse return error.TestUnexpectedResult;
    defer gpa.free(resolved);

    try std.testing.expectEqualStrings("/repo/shared/mod.zig", resolved);
}

test "SemanticContext.resolveImportPathAlloc resolves unscoped fallback imports" {
    var gpa = std.testing.allocator;

    const module_imports = [_]BuildInfo.ModuleImportEntry{
        .{
            .scope_id = null,
            .import_name = "pkg",
            .root_source_path = "/deps/pkg/root.zig",
        },
    };
    const build_info = BuildInfo{
        .module_imports = &module_imports,
    };
    const ctx = SemanticContext.init(&build_info);

    const resolved = ctx.resolveImportPathAlloc(
        "/repo/any/file.zig",
        "pkg",
        gpa,
    ) orelse return error.TestUnexpectedResult;
    defer gpa.free(resolved);

    try std.testing.expectEqualStrings("/deps/pkg/root.zig", resolved);
}
