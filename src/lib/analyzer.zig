//! Shared analyzers

/// Returns true if the tree is of a file that's an implicit struct with fields and not namespace
pub fn isRootImplicitStruct(tree: std.zig.Ast) bool {
    return !isContainerNamespace(tree, tree.containerDeclRoot());
}

pub fn isContainerNamespace(tree: std.zig.Ast, container_decl: std.zig.Ast.full.ContainerDecl) bool {
    for (container_decl.ast.members) |member| {
        if (shims.nodeTag(tree, member).isContainerField()) return false;
    }
    return true;
}

const shims = @import("shims.zig");
const std = @import("std");
