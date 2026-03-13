//! Utilities for interacting with Zig AST
//!
//! Types and functions may not all be shims in the traditional definition
//! sense. I've used the name to give the caller some sense that its "safe" to
//! call between zig versions.
//!
//! Perhaps one day this becomes more of a bag of AST utils instead "shims".

/// A quick shim for node index as it was a u32 but is now a packed u32 enum.
/// If it's an `OptionalIndex` in 0.15 then use `initOptional`, otherwise use
/// `init`.
pub const NodeIndexShim = struct {
    index: u32,

    pub const root: NodeIndexShim = .{ .index = 0 };

    pub inline fn isRoot(self: NodeIndexShim) bool {
        return self.index == 0;
    }

    /// Supports init from Index, u32, see initOptional for optionals in 0.15
    pub inline fn init(node: anytype) NodeIndexShim {
        return switch (@typeInfo(@TypeOf(node))) {
            .@"enum" => .{
                .index = @intFromEnum(
                    if (std.meta.hasFn(@TypeOf(node), "unwrap"))
                        @compileError("OptionalIndex should use initOptional as zero does not mean root but emptiness in 0.14")
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

    pub inline fn toNodeIndex(self: NodeIndexShim) Ast.Node.Index {
        return switch (@typeInfo(Ast.Node.Index)) {
            .@"enum" => @enumFromInt(self.index), // >= 0.15.x
            else => self.index, // == 0.14.x
        };
    }

    pub fn compare(_: void, self: NodeIndexShim, other: NodeIndexShim) std.math.Order {
        return std.math.order(self.index, other.index);
    }
};

const std = @import("std");
const Ast = std.zig.Ast;
