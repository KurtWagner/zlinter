pub const max_zig_file_size_bytes = bytes: {
    const bytes_in_mb = 1024 * 1024;
    break :bytes 32 * bytes_in_mb;
};

/// Returns true if the if statement appears to enforce that its block is test only
pub fn isTestOnlyCondition(tree: Ast, if_statement: Ast.full.If) bool {
    const cond_node = if_statement.ast.cond_expr;
    return switch (tree.nodeTag(cond_node)) {
        .identifier => std.mem.eql(u8, "is_test", tree.getNodeSource(cond_node)),
        .field_access => ast.isFieldVarAccess(tree, cond_node, &.{"is_test"}),
        else => false,
    };
}

const ast = @import("../ast.zig");
const std = @import("std");
const Ast = std.zig.Ast;

test {
    std.testing.refAllDecls(@This());
}
