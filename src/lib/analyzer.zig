//! Shared analyzers

/// Returns true if the tree is of a file that's an implicit struct with fields and not namespace
pub fn isRootImplicitStruct(tree: std.zig.Ast) bool {
    for (tree.containerDeclRoot().ast.members) |member| {
        if (nodeTag(tree, member).isContainerField()) return true;
    }
    return false;
}

pub fn nodeTag(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) std.zig.Ast.Node.Tag {
    if (std.meta.hasMethod(@TypeOf(tree), "nodeTag")) {
        return tree.nodeTag(node);
    }
    return tree.nodes.items(.tag)[node]; // 0.14.x
}

pub fn nodeMainToken(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) std.zig.Ast.TokenIndex {
    if (std.meta.hasMethod(@TypeOf(tree), "nodeMainToken")) {
        return tree.nodeMainToken(node);
    }
    return tree.nodes.items(.main_token)[node]; // 0.14.x
}

pub fn nodeData(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) std.zig.Ast.Node.Data {
    if (std.meta.hasMethod(@TypeOf(tree), "nodeData")) {
        return tree.nodeData(node);
    }
    return tree.nodes.items(.data)[node]; // 0.14.x
}

pub const NodeIndexShim = struct {
    index: u32,

    /// Supports init from OptionalIndex, Index, u32
    pub inline fn init(node: anytype) NodeIndexShim {
        return switch (@typeInfo(@TypeOf(node))) {
            .@"enum" => .{ .index = @intFromEnum(if (std.meta.hasFn(@TypeOf(node), "unwrap"))
                node.unwrap().?
            else
                node) },
            else => .{ .index = node },
        };
    }

    pub inline fn toNodeIndex(self: NodeIndexShim) std.zig.Ast.Node.Index {
        return switch (@typeInfo(std.zig.Ast.Node.Index)) {
            .@"enum" => @enumFromInt(self.index), // >= 0.15.x
            else => self.index, // == 0.14.x
        };
    }
};

const std = @import("std");
