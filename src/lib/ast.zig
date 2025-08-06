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

/// Temporary work around to bug in zls 0.14 that's now fixed in zls master.
/// I don't see the point in upstreaming the fix to the ZLS 0.14 branch so
/// leaving this simple work around in place while we support 0.14 and then it
/// can be deleted.
pub fn iterateChildren(
    tree: std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    context: anytype,
    comptime Error: type,
    comptime callback: fn (@TypeOf(context), std.zig.Ast, std.zig.Ast.Node.Index) Error!void,
) Error!void {
    switch (version.zig) {
        .@"0.14" => {
            if (shims.nodeTag(tree, node) == .fn_decl) {
                try callback(context, tree, shims.nodeData(tree, node).lhs);
                try callback(context, tree, shims.nodeData(tree, node).rhs);
            } else {
                try zls.ast.iterateChildren(tree, node, context, Error, callback);
            }
        },
        .@"0.15" => try zls.ast.iterateChildren(tree, node, context, Error, callback),
    }
}

/// `errdefer` and `defer` calls
pub const DeferBlock = struct {
    children: []const std.zig.Ast.Node.Index,

    pub fn deinit(self: DeferBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.children);
    }
};

pub fn deferBlock(doc: session.LintDocument, node: std.zig.Ast.Node.Index, allocator: std.mem.Allocator) !?DeferBlock {
    const tree = doc.handle.tree;

    const data = shims.nodeData(tree, node);
    const exp_node =
        switch (shims.nodeTag(tree, node)) {
            .@"errdefer" => switch (version.zig) {
                .@"0.14" => data.rhs,
                .@"0.15" => data.opt_token_and_node[1],
            },
            .@"defer" => switch (version.zig) {
                .@"0.14" => data.rhs,
                .@"0.15" => data.node,
            },
            else => return null,
        };

    if (isBlock(tree, exp_node)) {
        return .{ .children = try allocator.dupe(std.zig.Ast.Node.Index, doc.lineage.items(.children)[shims.NodeIndexShim.init(exp_node).index] orelse &.{}) };
    } else {
        return .{ .children = try allocator.dupe(std.zig.Ast.Node.Index, &.{exp_node}) };
    }
}

pub fn isBlock(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (shims.nodeTag(tree, node)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => true,
        else => false,
    };
}

test "deferBlock - has expected children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    inline for (&.{
        .{
            \\defer {}
            ,
            &.{},
        },
        .{
            \\errdefer {}
            ,
            &.{},
        },
        .{
            \\defer me.deinit();
            ,
            &.{"me.deinit()"},
        },
        .{
            \\defer {
            \\  me.run();
            \\  me.deinit(arena);
            \\}
            ,
            &.{ "me.run()", "me.deinit(arena)" },
        },
        .{
            \\errdefer me.deinit();
            ,
            &.{"me.deinit()"},
        },
        .{
            \\errdefer {
            \\  me.run();
            \\  me.deinit(arena);
            \\}
            ,
            &.{ "me.run()", "me.deinit(arena)" },
        },
        .{
            \\errdefer |e| me.deinit();
            ,
            &.{"me.deinit()"},
        },
        .{
            \\errdefer |err| {
            \\  me.run();
            \\  me.deinit(arena);
            \\}
            ,
            &.{ "me.run()", "me.deinit(arena)" },
        },
    }) |tuple| {
        const source, const expected = tuple;
        defer _ = arena.reset(.retain_capacity);

        var ctx: session.LintContext = undefined;
        try ctx.init(.{}, std.testing.allocator);
        defer ctx.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var doc = (try testing.loadFakeDocument(
            &ctx,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        )).?;
        defer doc.deinit(ctx.gpa);

        const decl_ref = try deferBlock(
            doc,
            try testing.expectSingleNodeOfTag(doc.handle.tree, &.{ .@"defer", .@"errdefer" }),
            std.testing.allocator,
        );
        defer if (decl_ref) |d| d.deinit(std.testing.allocator);

        testing.expectNodeSlices(expected, doc.handle.tree, decl_ref.?.children) catch |e| {
            std.debug.print("Failed source: '{s}'\n", .{source});
            return e;
        };
    }
}

const std = @import("std");
const zls = @import("zls");
const shims = @import("shims.zig");
const version = @import("version.zig");
const testing = @import("testing.zig");
const session = @import("session.zig");
