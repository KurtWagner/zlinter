const std = @import("std");
const Ast = std.zig.Ast;

pub fn regression(tree: Ast, node: Ast.Node.Index) void {
    switch (tree.nodeTag(node)) {
        .identifier => {},
        else => {},
    }
}
