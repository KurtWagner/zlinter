const std = @import("std");
const Ast = std.zig.Ast;

fn kind(tree: Ast, node: Ast.Node.Index) Ast.Node.Tag {
    return tree.nodeTag(node);
}

pub fn regression(tree: Ast, node: Ast.Node.Index) void {
    switch (kind(tree, node)) {
        .identifier => {},
        else => {},
    }
}
