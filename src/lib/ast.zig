//! AST navigation helpers

pub const NodeLineage = std.MultiArrayList(NodeConnections);

pub const NodeConnections = struct {
    /// Null if root
    parent: ?std.zig.Ast.Node.Index = null,
    children: ?[]const std.zig.Ast.Node.Index = null,

    pub fn deinit(self: NodeConnections, allocator: std.mem.Allocator) void {
        if (self.children) |c| allocator.free(c);
    }
};

pub const NodeAncestorIterator = struct {
    const Self = @This();

    current: shims.NodeIndexShim,
    lineage: *NodeLineage,
    done: bool = false,

    pub fn next(self: *Self) ?std.zig.Ast.Node.Index {
        if (self.done or self.current.isRoot()) return null;

        const parent = self.lineage.items(.parent)[self.current.index];
        if (parent) |p| {
            self.current = shims.NodeIndexShim.init(p);
            return p;
        } else {
            self.done = true;
            return null;
        }
    }
};

pub const NodeLineageIterator = struct {
    const Self = @This();

    queue: std.ArrayListUnmanaged(shims.NodeIndexShim) = .empty,
    lineage: *NodeLineage,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *NodeLineageIterator) void {
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn next(self: *Self) error{OutOfMemory}!?struct { shims.NodeIndexShim, NodeConnections } {
        if (self.queue.pop()) |node_shim| {
            const connections = self.lineage.get(node_shim.index);
            for (connections.children orelse &.{}) |child| {
                try self.queue.append(self.gpa, .init(child));
            }
            return .{ node_shim, connections };
        }
        return null;
    }
};

pub fn nodeChildrenAlloc(
    gpa: std.mem.Allocator,
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) error{OutOfMemory}![]std.zig.Ast.Node.Index {
    const Context = struct {
        gpa: std.mem.Allocator,
        children: *std.ArrayListUnmanaged(std.zig.Ast.Node.Index),

        fn callback(self: @This(), _: std.zig.Ast, child_node: std.zig.Ast.Node.Index) error{OutOfMemory}!void {
            if (shims.NodeIndexShim.init(child_node).isRoot()) return;
            try self.children.append(self.gpa, child_node);
        }
    };

    var children: std.ArrayListUnmanaged(std.zig.Ast.Node.Index) = .empty;
    defer children.deinit(gpa);

    try iterateChildren(
        tree,
        node,
        Context{
            .gpa = gpa,
            .children = &children,
        },
        error{OutOfMemory},
        Context.callback,
    );
    return children.toOwnedSlice(gpa);
}

/// Temporary work around to bug in zls that will hopefully be accepted upstream
/// Basically its not walking the fn decl and then its fn proto, its treating
/// them as one in the same.
pub fn iterateChildren(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    context: anytype,
    comptime Error: type,
    comptime callback: fn (@TypeOf(context), std.zig.Ast, std.zig.Ast.Node.Index) Error!void,
) Error!void {
    if (shims.nodeTag(tree, node) == .fn_decl) {
        // const ctx = struct {
        //     fn inner(ctx: *const anyopaque, t: std.zig.Ast, n: std.zig.Ast.Node.Index) anyerror!void {
        //         return callback(@as(*const @TypeOf(context), @alignCast(@ptrCast(ctx))).*, t, n);
        //     }
        // };
        switch (version.zig) {
            .@"0.14" => {
                try callback(context, tree, shims.nodeData(tree, node).lhs);
                try callback(context, tree, shims.nodeData(tree, node).rhs);
            },
            .@"0.15" => {
                try callback(context, tree, shims.nodeData(tree, node).node_and_node[0]);
                try callback(context, tree, shims.nodeData(tree, node).node_and_node[1]);
            },
        }
    } else {
        try zls.ast.iterateChildren(tree, node, context, Error, callback);
    }
}

const std = @import("std");
const zls = @import("zls");
const shims = @import("shims.zig");
const version = @import("version.zig");
