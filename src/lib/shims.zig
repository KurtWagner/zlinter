pub const NodeIndexShim = struct {
    index: u32,

    /// Supports init from Index, u32, see initOptional for optionals in 0.15
    pub inline fn init(node: anytype) NodeIndexShim {
        return switch (@typeInfo(@TypeOf(node))) {
            .@"enum" => .{
                .index = @intFromEnum(
                    if (std.meta.hasFn(@TypeOf(node), "unwrap"))
                        node.unwrap() orelse .root
                    else
                        node,
                ),
            },
            else => .{ .index = node },
        };
    }

    pub inline fn initOptional(node: anytype) ?NodeIndexShim {
        return switch (@typeInfo(@TypeOf(node))) {
            .@"enum" => .{
                .index = if (std.meta.hasFn(@TypeOf(node), "unwrap"))
                    if (node.unwrap()) |n| @intFromEnum(n) else return null
                else
                    return @intFromEnum(node),
            },
            else => .{ .index = if (node == 0) return null else node },
        };
    }

    pub inline fn toNodeIndex(self: NodeIndexShim) std.zig.Ast.Node.Index {
        return switch (@typeInfo(std.zig.Ast.Node.Index)) {
            .@"enum" => @enumFromInt(self.index), // >= 0.15.x
            else => self.index, // == 0.14.x
        };
    }
};

pub fn isIdentiferKind(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    kind: enum { type },
) bool {
    return switch (nodeTag(tree, node)) {
        .identifier => switch (kind) {
            .type => std.mem.eql(u8, "type", tree.tokenSlice(nodeMainToken(tree, node))),
        },
        else => false,
    };
}

/// Unwraps pointers and optional nodes to the underlying node
pub fn unwrapNode(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    options: struct {
        // ?T => T
        unwrap_optional: bool = true,
        // *T => T
        unwrap_pointer: bool = true,
        // T.? => T
        unwrap_optional_unwrap: bool = true,
    },
) std.zig.Ast.Node.Index {
    var current = node;

    while (true) {
        switch (nodeTag(tree, current)) {
            .unwrap_optional => if (options.unwrap_optional_unwrap) switch (version.zig) {
                .@"0.14" => current = nodeData(tree, current).lhs,
                .@"0.15" => current = nodeData(tree, current).node_and_token.@"0",
            } else break,
            .optional_type => if (options.unwrap_optional) switch (version.zig) {
                .@"0.14" => current = nodeData(tree, current).lhs,
                .@"0.15" => current = nodeData(tree, current).node,
            } else break,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            => if (options.unwrap_pointer) switch (version.zig) {
                .@"0.14" => current = nodeData(tree, current).rhs,
                .@"0.15" => current = nodeData(tree, current).opt_node_and_node.@"1",
            } else break,
            else => break,
        }
    }
    return current;
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

const std = @import("std");
const version = @import("version.zig");
