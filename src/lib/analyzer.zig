//! Shared analyzers

/// Returns true if the tree is of a file that's an implicit struct with fields and not namespace
pub fn isRootImplicitStruct(tree: std.zig.Ast) bool {
    for (tree.containerDeclRoot().ast.members) |member| {
        if (tree.nodes.items(.tag)[member].isContainerField()) return true;
    }
    return false;
}

/// Returns true if type is a function (or a pointer to a function)
pub fn isTypeFunction(t: zls.Analyser.Type) bool {
    if (t.isTypeFunc()) return true;
    return switch (t.data) {
        .pointer => |info| isTypeFunction(info.elem_ty.*),
        else => false,
    };
}

/// Returns true if type is a type function (or a pointer to a type function)
pub fn isFunction(t: zls.Analyser.Type) bool {
    if (t.isFunc()) return true;
    return switch (t.data) {
        .pointer => |info| isFunction(info.elem_ty.*),
        else => false,
    };
}

const std = @import("std");
const zls = @import("zls");
