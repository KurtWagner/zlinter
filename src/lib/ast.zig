//! AST navigation helpers

pub const NodeLineage = std.MultiArrayList(NodeConnections);

pub const NodeConnections = struct {
    /// Null if root
    parent: ?Ast.Node.Index = null,
    children: ?[]const Ast.Node.Index = null,

    pub fn deinit(self: NodeConnections, allocator: std.mem.Allocator) void {
        if (self.children) |c| allocator.free(c);
    }
};

pub const NodeAncestorIterator = struct {
    const Self = @This();

    current: NodeIndexShim,
    lineage: *NodeLineage,
    done: bool = false,

    pub fn next(self: *Self) ?Ast.Node.Index {
        if (self.done or self.current.isRoot()) return null;

        const parent = self.lineage.items(.parent)[self.current.index];
        if (parent) |p| {
            self.current = NodeIndexShim.init(p);
            return p;
        } else {
            self.done = true;
            return null;
        }
    }
};

pub const NodeLineageIterator = struct {
    const Self = @This();

    queue: shims.ArrayList(NodeIndexShim) = .empty,
    lineage: *NodeLineage,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *NodeLineageIterator) void {
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn next(self: *Self) error{OutOfMemory}!?struct { NodeIndexShim, NodeConnections } {
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
    tree: Ast,
    node: Ast.Node.Index,
) error{OutOfMemory}![]Ast.Node.Index {
    const Context = struct {
        gpa: std.mem.Allocator,
        children: *shims.ArrayList(Ast.Node.Index),

        fn callback(self: @This(), _: Ast, child_node: Ast.Node.Index) error{OutOfMemory}!void {
            if (NodeIndexShim.init(child_node).isRoot()) return;
            try self.children.append(self.gpa, child_node);
        }
    };

    var children: shims.ArrayList(Ast.Node.Index) = .empty;
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
    tree: Ast,
    node: Ast.Node.Index,
    context: anytype,
    comptime Error: type,
    comptime callback: fn (@TypeOf(context), Ast, Ast.Node.Index) Error!void,
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
        .@"0.15", .@"0.16" => try zls.ast.iterateChildren(tree, node, context, Error, callback),
    }
}

/// `errdefer` and `defer` calls
pub const DeferBlock = struct {
    children: []const Ast.Node.Index,

    pub fn deinit(self: DeferBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.children);
    }
};

pub fn deferBlock(doc: session.LintDocument, node: Ast.Node.Index, allocator: std.mem.Allocator) !?DeferBlock {
    const tree = doc.handle.tree;

    const data = shims.nodeData(tree, node);
    const exp_node =
        switch (shims.nodeTag(tree, node)) {
            .@"errdefer" => switch (version.zig) {
                .@"0.14" => data.rhs,
                .@"0.15", .@"0.16" => data.opt_token_and_node[1],
            },
            .@"defer" => switch (version.zig) {
                .@"0.14" => data.rhs,
                .@"0.15", .@"0.16" => data.node,
            },
            else => return null,
        };

    if (isBlock(tree, exp_node)) {
        return .{ .children = try allocator.dupe(Ast.Node.Index, doc.lineage.items(.children)[NodeIndexShim.init(exp_node).index] orelse &.{}) };
    } else {
        return .{ .children = try allocator.dupe(Ast.Node.Index, &.{exp_node}) };
    }
}

pub fn isBlock(tree: Ast, node: Ast.Node.Index) bool {
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
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

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

        try testing.expectNodeSlices(expected, doc.handle.tree, decl_ref.?.children);
    }
}

/// Returns true if return type is `!type` or `error{ErrorName}!type` or `ErrorName!type`
pub fn fnProtoReturnsError(tree: Ast, fn_proto: Ast.full.FnProto) bool {
    const return_node = NodeIndexShim.initOptional(fn_proto.ast.return_type) orelse return false;
    const tag = shims.nodeTag(tree, return_node.toNodeIndex());
    return switch (tag) {
        .error_union => true,
        else => tree.tokens.items(.tag)[tree.firstToken(return_node.toNodeIndex()) - 1] == .bang,
    };
}

test "fnProtoReturnsError" {
    var buffer: [1]Ast.Node.Index = undefined;
    inline for (&.{
        .{
            \\ fn func() !void;
            ,
            true,
        },
        .{
            \\ fn func() !u32;
            ,
            true,
        },
        .{
            \\ fn func() !?u32;
            ,
            true,
        },
        .{
            \\ fn func() u32;
            ,
            false,
        },
        .{
            \\ fn func() void;
            ,
            false,
        },
        .{
            \\ fn func() error{ErrA, ErrB}!void;
            ,
            true,
        },
        .{
            \\ fn func() errors!void;
            ,
            true,
        },
        .{
            \\ fn func() errors!u32;
            ,
            true,
        },
        .{
            \\ fn func() errors!?u32;
            ,
            true,
        },
    }) |tuple| {
        const source, const expected = tuple;
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        var tree = try Ast.parse(std.testing.allocator, source, .zig);
        defer tree.deinit(std.testing.allocator);

        const actual = fnProtoReturnsError(
            tree,
            tree.fullFnProto(
                &buffer,
                try testing.expectSingleNodeOfTag(
                    tree,
                    &.{
                        .fn_proto,
                        .fn_proto_multi,
                        .fn_proto_one,
                        .fn_proto_simple,
                        .fn_decl,
                    },
                ),
            ).?,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

pub const FnDecl = struct {
    proto: Ast.full.FnProto,
    block: Ast.Node.Index,
};

/// Returns the function declaration (proto and block) if node is a function declaration,
/// otherwise returns null.
pub fn fnDecl(tree: Ast, node: Ast.Node.Index, fn_proto_buffer: *[1]Ast.Node.Index) ?FnDecl {
    switch (shims.nodeTag(tree, node)) {
        .fn_decl => {
            const data = shims.nodeData(tree, node);
            const lhs, const rhs = switch (version.zig) {
                .@"0.14" => .{ data.lhs, data.rhs },
                .@"0.15", .@"0.16" => .{ data.node_and_node[0], data.node_and_node[1] },
            };
            return .{ .proto = tree.fullFnProto(fn_proto_buffer, lhs).?, .block = rhs };
        },
        else => return null,
    }
}

/// Returns a token of an identifier for the field access of a node if the
/// node is in fact a field access node.
///
/// For example `parent.ok` and `parent.child.ok` would return a token index
/// pointing to `ok`.
pub fn fieldVarAccess(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    if (shims.nodeTag(tree, node) != .field_access) return null;

    const last_token = tree.lastToken(node);
    const last_token_tag = shims.tokenTag(tree, last_token);

    return switch (last_token_tag) {
        .identifier => last_token,
        else => null,
    };
}

/// Returns true if the node is a field access and is accessing a given var name
/// as the final access.
///
/// For example, `parent.ok` and `parent.child.ok` would match var name `ok` but
/// not `child` (even though it is a field access above `ok`).
pub fn isFieldVarAccess(tree: Ast, node: Ast.Node.Index, var_names: []const []const u8) bool {
    const identifier_token = fieldVarAccess(tree, node) orelse return false;
    const actual_var_name = tree.tokenSlice(identifier_token);

    for (var_names) |var_name| {
        if (std.mem.eql(u8, actual_var_name, var_name)) return true;
    }
    return false;
}

pub const Statement = union(enum) {
    @"if": Ast.full.If,
    @"while": Ast.full.While,
    @"for": Ast.full.For,
    switch_case: Ast.full.SwitchCase,
    /// Contains the expression node index (i.e., `catch <expr>`)
    @"catch": Ast.Node.Index,
    /// Contains the expression node index (i.e., `defer <expr>`)
    @"defer": Ast.Node.Index,
    /// Contains the expression node index (i.e., `errdefer <expr>`)
    @"errdefer": Ast.Node.Index,

    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .@"if" => "if",
            .@"while" => "while",
            .@"for" => "for",
            .switch_case => "switch case",
            .@"catch" => "catch",
            .@"defer" => "defer",
            .@"errdefer" => "errdefer",
        };
    }
};

/// Returns if, for, while, switch case, defer and errdefer and catch statements
/// focusing on the expression node attached, which is relevant in whether or not
/// it's a block enclosed in braces.
pub fn fullStatement(tree: Ast, node: Ast.Node.Index) ?Statement {
    return if (tree.fullIf(node)) |ifStatement|
        .{ .@"if" = ifStatement }
    else if (tree.fullWhile(node)) |whileStatement|
        .{ .@"while" = whileStatement }
    else if (tree.fullFor(node)) |forStatement|
        .{ .@"for" = forStatement }
    else if (tree.fullSwitchCase(node)) |switchStatement|
        .{ .switch_case = switchStatement }
    else switch (shims.nodeTag(tree, node)) {
        .@"catch" => .{
            .@"catch" = switch (version.zig) {
                .@"0.14" => shims.nodeData(tree, node).rhs,
                .@"0.15", .@"0.16" => shims.nodeData(tree, node).node_and_node[1],
            },
        },
        .@"defer" => .{
            .@"defer" = switch (version.zig) {
                .@"0.14" => shims.nodeData(tree, node).rhs,
                .@"0.15", .@"0.16" => shims.nodeData(tree, node).node,
            },
        },
        .@"errdefer" => .{
            .@"errdefer" = switch (version.zig) {
                .@"0.14" => shims.nodeData(tree, node).rhs,
                .@"0.15", .@"0.16" => shims.nodeData(tree, node).opt_token_and_node[1],
            },
        },
        else => null,
    };
}

// TODO: Add unit tests for this
pub fn isFnPrivate(tree: Ast, fn_decl: Ast.full.FnProto) bool {
    const visibility_token = fn_decl.visib_token orelse return true;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => false,
        else => true,
    };
}

// TODO: Add unit tests for this
pub fn isVarPrivate(tree: Ast, var_decl: Ast.full.VarDecl) bool {
    const visibility_token = var_decl.visib_token orelse return true;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => false,
        else => true,
    };
}

test "isFieldVarAccess" {
    inline for (&.{
        .{
            \\ var var_name = .not_field_access;
            ,
            &.{"not_field_access"},
            false,
        },
        .{
            \\ var var_name = parent.notVarButCall();
            ,
            &.{ "parent", "notVarButCall" },
            false,
        },
        .{
            \\ var var_name = parent.good;
            ,
            &.{"good"},
            true,
        },
        .{
            \\ var var_name = parent.also.good;
            ,
            &.{ "other", "good" },
            true,
        },
        .{
            \\ var var_name = parent.also.good;
            ,
            &.{
                "other",
            },
            false,
        },
        .{
            \\ var var_name = parent.also.good;
            ,
            &.{
                "parent", "also",
            },
            false,
        },
    }) |tuple| {
        const source, const names, const expected = tuple;
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        var tree = try Ast.parse(
            std.testing.allocator,
            source,
            .zig,
        );
        defer tree.deinit(std.testing.allocator);

        const actual = isFieldVarAccess(
            tree,
            NodeIndexShim.initOptional(tree.fullVarDecl(try testing.expectSingleNodeOfTag(
                tree,
                &.{
                    .local_var_decl,
                    .global_var_decl,
                    .simple_var_decl,
                    .aligned_var_decl,
                },
            )).?.ast.init_node).?.toNodeIndex(),
            names,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

/// Returns true if enum literal matching a given var name
pub fn isEnumLiteral(tree: Ast, node: Ast.Node.Index, enum_names: []const []const u8) bool {
    if (shims.nodeTag(tree, node) != .enum_literal) return false;

    const actual_enum_name = tree.tokenSlice(shims.nodeMainToken(tree, node));
    for (enum_names) |enum_name| {
        if (std.mem.eql(u8, actual_enum_name, enum_name)) return true;
    }
    return false;
}

test "isEnumLiteral" {
    inline for (&.{
        .{
            \\ var var_name = .enum_name;
            ,
            &.{"enum_name"},
            true,
        },
        .{
            \\ var var_name = .enum_name;
            ,
            &.{ "other", "enum_name" },
            true,
        },
        .{
            \\ var var_name = .enum_name;
            ,
            &.{"other"},
            false,
        },
        .{
            \\ var var_name = not.literal;
            ,
            &.{"literal"},
            false,
        },
        .{
            \\ var var_name = not.literal();
            ,
            &.{"literal"},
            false,
        },
        .{
            \\ var var_name = notLiteral();
            ,
            &.{"notLiteral"},
            false,
        },
    }) |tuple| {
        const source, const names, const expected = tuple;
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        var tree = try Ast.parse(
            std.testing.allocator,
            source,
            .zig,
        );
        defer tree.deinit(std.testing.allocator);

        const actual = isEnumLiteral(
            tree,
            NodeIndexShim.initOptional(tree.fullVarDecl(try testing.expectSingleNodeOfTag(
                tree,
                &.{
                    .local_var_decl,
                    .global_var_decl,
                    .simple_var_decl,
                    .aligned_var_decl,
                },
            )).?.ast.init_node).?.toNodeIndex(),
            names,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

const session = @import("session.zig");
const shims = @import("shims.zig");
const std = @import("std");
const testing = @import("testing.zig");
const version = @import("version.zig");
const zls = @import("zls");
const NodeIndexShim = shims.NodeIndexShim;
const Ast = std.zig.Ast;
