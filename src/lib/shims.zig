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

/// Returns true if identifier node and itentifier node has the given kind.
pub fn isIdentiferKind(
    tree: Ast,
    node: Ast.Node.Index,
    kind: enum { type },
) bool {
    return switch (nodeTag(tree, node)) {
        .identifier => switch (kind) {
            .type => std.mem.eql(u8, "type", tree.tokenSlice(nodeMainToken(tree, node))),
        },
        else => false,
    };
}

/// Unwraps pointers and optional nodes to the underlying node, this is useful
/// when linting based on the underlying type of a field or argument.
///
/// For example if you want `?StructType` to be treated the same as `StructType`.
pub fn unwrapNode(
    tree: Ast,
    node: Ast.Node.Index,
    options: struct {
        /// i.e., ?T => T
        unwrap_optional: bool = true,
        /// i.e., *T => T
        unwrap_pointer: bool = true,
        /// i.e., T.? => T
        unwrap_optional_unwrap: bool = true,
    },
) Ast.Node.Index {
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
            => if (options.unwrap_pointer) switch (version.zig) {
                .@"0.14" => current = nodeData(tree, current).rhs,
                .@"0.15" => current = nodeData(tree, current).opt_node_and_node.@"1",
            } else break,
            .ptr_type,
            => if (options.unwrap_pointer) switch (version.zig) {
                .@"0.14" => current = nodeData(tree, current).rhs,
                .@"0.15" => current = nodeData(tree, current).extra_and_node.@"1",
            } else break,
            else => break,
        }
    }
    return current;
}

pub fn tokenTag(tree: Ast, token: Ast.TokenIndex) std.zig.Token.Tag {
    return if (std.meta.hasMethod(@TypeOf(tree), "tokenTag"))
        tree.tokenTag(token)
    else
        tree.tokens.items(.tag)[token]; // 0.14.x
}

pub fn nodeTag(tree: Ast, node: Ast.Node.Index) Ast.Node.Tag {
    return if (std.meta.hasMethod(@TypeOf(tree), "nodeTag"))
        tree.nodeTag(node)
    else
        tree.nodes.items(.tag)[node]; // 0.14.x
}

pub fn nodeMainToken(tree: Ast, node: Ast.Node.Index) Ast.TokenIndex {
    return if (std.meta.hasMethod(@TypeOf(tree), "nodeMainToken"))
        tree.nodeMainToken(node)
    else
        tree.nodes.items(.main_token)[node]; // 0.14.x
}

pub fn nodeData(tree: Ast, node: Ast.Node.Index) Ast.Node.Data {
    return if (std.meta.hasMethod(@TypeOf(tree), "nodeData"))
        tree.nodeData(node)
    else
        tree.nodes.items(.data)[node]; // 0.14.x
}

// TODO: Write unit tests for this
/// Returns true if two non-root nodes are overlapping.
///
/// This can be useful if you have a node and want to work out where it's
/// contained (e.g., within a struct).
pub fn isNodeOverlapping(
    tree: Ast,
    a: Ast.Node.Index,
    b: Ast.Node.Index,
) bool {
    const node_a = NodeIndexShim.init(a);
    const node_b = NodeIndexShim.init(b);

    std.debug.assert(node_a.index != 0);
    std.debug.assert(node_b.index != 0);

    const span_a = tree.nodeToSpan(node_a.toNodeIndex());
    const span_b = tree.nodeToSpan(node_b.toNodeIndex());

    return (span_a.start >= span_b.start and span_a.start <= span_b.end) or
        (span_b.start >= span_a.start and span_b.start <= span_a.end);
}

/// Returns true if the tree is of a file that's an implicit struct with fields
/// and not namespace
pub fn isRootImplicitStruct(tree: Ast) bool {
    return !isContainerNamespace(tree, tree.containerDeclRoot());
}

/// Returns true if the container is a namespace (i.e., no fields just declarations)
pub fn isContainerNamespace(tree: Ast, container_decl: Ast.full.ContainerDecl) bool {
    for (container_decl.ast.members) |member| {
        if (nodeTag(tree, member).isContainerField()) return false;
    }
    return true;
}

/// Managed versions of ArrayList are being removed from std. While it's phased
/// out this can be used to consistently return an unmanaged version.
pub fn ArrayList(T: type) type {
    return comptime switch (version.zig) {
        .@"0.14" => std.ArrayListUnmanaged(T),
        .@"0.15" => std.ArrayList(T),
    };
}

const std = @import("std");
const version = @import("version.zig");
const Ast = std.zig.Ast;
