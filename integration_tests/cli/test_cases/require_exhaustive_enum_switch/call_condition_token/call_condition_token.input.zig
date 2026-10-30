const std = @import("std");
const Ast = std.zig.Ast;

pub fn regression(tree: Ast, token: Ast.TokenIndex) void {
    switch (tree.tokenTag(token)) {
        .identifier => {},
        else => {},
    }
}
