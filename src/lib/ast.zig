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
    lineage: *const NodeLineage,
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
    lineage: *const NodeLineage,
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

pub fn deferBlock(doc: *const session.LintDocument, node: Ast.Node.Index, allocator: std.mem.Allocator) !?DeferBlock {
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

        var context: session.LintContext = undefined;
        try context.init(.{}, std.testing.allocator, arena.allocator());
        defer context.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        );

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

/// Visibility of a node in the AST (e.g., a function or variable declaration).
pub const Visibility = enum { public, private };

/// Returns the visibility of a given function proto.
pub fn fnProtoVisibility(tree: Ast, fn_decl: Ast.full.FnProto) Visibility {
    const visibility_token = fn_decl.visib_token orelse return .private;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => .public,
        else => .private,
    };
}

/// Returns the visibility of a given variable declaration.
pub fn varDeclVisibility(tree: Ast, var_decl: Ast.full.VarDecl) Visibility {
    const visibility_token = var_decl.visib_token orelse return .private;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => .public,
        else => .private,
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

/// Checks whether the current node is a function call or contains one in its
/// children matching given case sensitive names.
pub fn findFnCall(
    doc: *const session.LintDocument,
    node: Ast.Node.Index,
    call_buffer: *[1]Ast.Node.Index,
    names: []const []const u8,
) ?FnCall {
    std.debug.assert(names.len > 0);

    if (fnCall(
        doc,
        node,
        call_buffer,
        names,
    )) |call| {
        return call;
    }

    for (doc.lineage.items(.children)[shims.NodeIndexShim.init(node).index] orelse &.{}) |child| {
        if (findFnCall(
            doc,
            child,
            call_buffer,
            names,
        )) |call| return call;
    }
    return null;
}

pub const FnCall = struct {
    params: []const Ast.Node.Index,

    /// The name of the function. For example,
    /// - single field: `parent.call()` would have `call` as the identifier token here.
    /// - other: `parent.child.call()` would have `call` as the identifier token here.
    /// - enum literal: `.init()` would have `init` here
    /// - direct: `doSomething()` would have `doSomething` here
    call_identifier_token: Ast.TokenIndex,

    kind: union(enum) {
        /// e.g., `parent.call()` not `parent.child.call()`
        single_field: struct {
            /// e.g., `parent.call()` would have `parent` as the main token here.
            field_main_token: Ast.TokenIndex,
        },
        /// array_access, unwrap_optional, nested field_access
        ///
        /// e.g., `parent.child.call()`, `optional.?.call()` and `array[0].call()`
        ///
        /// If there's value this can be broken up in the future but for now we do
        /// not need the separation.
        other: void,
        /// e.g., `.init()`
        enum_literal: void,
        /// e.g., `doSomething()`
        direct: void,
    },
};

/// If the given node is a call this returns call information, otherwise returns
/// null.
///
/// If names is empty, then it'll match all function names. Function names are
/// case sensitive.
pub fn fnCall(
    doc: *const session.LintDocument,
    node: Ast.Node.Index,
    buffer: *[1]Ast.Node.Index,
    names: []const []const u8,
) ?FnCall {
    const tree = doc.handle.tree;
    const call = tree.fullCall(buffer, node) orelse return null;

    const fn_expr_node = call.ast.fn_expr;
    const fn_expr_node_data = shims.nodeData(tree, fn_expr_node);
    const fn_expr_node_tag = shims.nodeTag(tree, fn_expr_node);

    const maybe_fn_call: ?FnCall = maybe_fn_call: {
        switch (fn_expr_node_tag) {
            // e.g., `parent.*`
            .field_access => {
                const field_node, const fn_name = switch (version.zig) {
                    .@"0.14" => .{ fn_expr_node_data.lhs, fn_expr_node_data.rhs },
                    .@"0.15", .@"0.16" => .{ fn_expr_node_data.node_and_token[0], fn_expr_node_data.node_and_token[1] },
                };
                std.debug.assert(shims.tokenTag(tree, fn_name) == .identifier);

                const field_node_tag = shims.nodeTag(tree, field_node);
                if (field_node_tag != .identifier) {
                    // e.g, array_access, unwrap_optional, field_access
                    break :maybe_fn_call .{
                        .params = call.ast.params,
                        .call_identifier_token = fn_name,
                        .kind = .{
                            .other = {},
                        },
                    };
                }
                // e.g., `parent.call()` not `parent.child.call()`
                break :maybe_fn_call .{
                    .params = call.ast.params,
                    .call_identifier_token = fn_name,
                    .kind = .{
                        .single_field = .{
                            .field_main_token = shims.nodeMainToken(tree, field_node),
                        },
                    },
                };
            },
            // e.g., `.init()`
            .enum_literal => {
                const fn_name = shims.nodeMainToken(tree, fn_expr_node);
                std.debug.assert(shims.tokenTag(tree, fn_name) == .identifier);

                break :maybe_fn_call .{
                    .params = call.ast.params,
                    .call_identifier_token = fn_name,
                    .kind = .{
                        .enum_literal = {},
                    },
                };
            },
            .identifier => {
                break :maybe_fn_call .{
                    .params = call.ast.params,
                    .call_identifier_token = shims.nodeMainToken(tree, fn_expr_node),
                    .kind = .{
                        .direct = {},
                    },
                };
            },
            else => std.log.debug("fnCall does not handle fn_expr of tag {s}", .{@tagName(fn_expr_node_tag)}),
        }
        break :maybe_fn_call null;
    };

    if (maybe_fn_call) |fn_call| {
        const fn_name_slice = doc.handle.tree.tokenSlice(fn_call.call_identifier_token);
        if (names.len == 0) return fn_call;

        for (names) |name| {
            if (std.mem.eql(u8, name, fn_name_slice)) {
                return fn_call;
            }
        }
    }
    return null;
}

test "fnCall - direct call without params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var context: session.LintContext = undefined;
    try context.init(.{}, std.testing.allocator, arena.allocator());
    defer context.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const doc = try testing.loadFakeDocument(
        &context,
        tmp.dir,
        "test.zig",
        \\fn main() void {
        \\  call();
        \\}
    ,
        arena.allocator(),
    );

    const fn_node = try testing.expectSingleNodeOfTag(
        doc.handle.tree,
        &.{ .call, .call_comma, .call_one, .call_one_comma },
    );
    var buffer: [1]Ast.Node.Index = undefined;
    const call = fnCall(
        doc,
        fn_node,
        &buffer,
        &.{},
    ).?;

    try std.testing.expectEqualDeep(&.{}, call.params);
    try std.testing.expectEqualStrings(
        "call",
        doc.handle.tree.tokenSlice(call.call_identifier_token),
    );
    try std.testing.expectEqualStrings("direct", @tagName(call.kind));
}

test "fnCall - single field call with params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var context: session.LintContext = undefined;
    try context.init(.{}, std.testing.allocator, arena.allocator());
    defer context.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const doc = try testing.loadFakeDocument(
        &context,
        tmp.dir,
        "test.zig",
        \\fn main() void {
        \\  single.fnName(1, abc);
        \\}
    ,
        arena.allocator(),
    );

    const fn_node = try testing.expectSingleNodeOfTag(
        doc.handle.tree,
        &.{ .call, .call_comma, .call_one, .call_one_comma },
    );
    var buffer: [1]Ast.Node.Index = undefined;
    const call = fnCall(
        doc,
        fn_node,
        &buffer,
        &.{},
    ).?;

    try std.testing.expectEqual(2, call.params.len);
    try std.testing.expectEqualStrings("1", doc.handle.tree.getNodeSource(call.params[0]));
    try std.testing.expectEqualStrings("abc", doc.handle.tree.getNodeSource(call.params[1]));
    try std.testing.expectEqualStrings(
        "single",
        doc.handle.tree.tokenSlice(call.kind.single_field.field_main_token),
    );
    try std.testing.expectEqualStrings(
        "fnName",
        doc.handle.tree.tokenSlice(call.call_identifier_token),
    );
}

test "findFnCall" {
    inline for (&.{
        \\fn main() void {
        \\  fnName();
        \\}
        ,
        \\fn main(age: u32) void {
        \\  if (age > 10) {
        \\    single.fnName();
        \\  }
        \\}
        ,
        \\fn main() void {
        \\  defer {
        \\    deep[0].?.fnName();
        \\  }
        \\}
        ,
        \\fn main(age: u32) void {
        \\  defer {
        \\    if (age > 10) .fnName();
        \\  }
        \\}
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        errdefer std.debug.print("Failed source: '{s}'\n", .{source});

        var context: session.LintContext = undefined;
        try context.init(.{}, std.testing.allocator, arena.allocator());
        defer context.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            source,
            arena.allocator(),
        );

        var buffer: [1]Ast.Node.Index = undefined;

        try std.testing.expectEqualStrings(
            "fnName",
            doc.handle.tree.tokenSlice(findFnCall(
                doc,
                shims.NodeIndexShim.root.toNodeIndex(),
                &buffer,
                &.{"fnName"},
            ).?.call_identifier_token),
        );

        try std.testing.expectEqual(
            null,
            findFnCall(
                doc,
                shims.NodeIndexShim.root.toNodeIndex(),
                &buffer,
                &.{ "fn", "Name", "fnname" },
            ),
        );
    }
}

pub const Scope = struct {
    node_index: Ast.Node.Index,
    parent: ?Index,
    symbols: std.StringHashMap(Ast.Node.Index),

    pub const Index = u32;

    pub fn init(
        gpa: std.mem.Allocator,
        node_index: Ast.Node.Index,
        options: struct { parent: ?Index = null },
    ) Scope {
        return .{
            .node_index = node_index,
            .symbols = .init(gpa),
            .parent = options.parent,
        };
    }

    pub fn deinit(self: *Scope, gpa: std.mem.Allocator) void {
        var it = self.symbols.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
        }
        self.symbols.deinit();
    }

    /// Adds a symbol to the scope where the key duplicated and owned by the
    /// scope instance, which will be freed in `deinit(gpa)`.
    pub fn addSymbol(
        self: *Scope,
        gpa: std.mem.Allocator,
        name: []const u8,
        index: Ast.Node.Index,
    ) error{OutOfMemory}!void {
        if (self.symbols.contains(name)) {
            // TODO: zlinter needs to log warnings.
            std.debug.panic("Symbol {s} already exists", .{name});
        }

        try self.symbols.put(try gpa.dupe(u8, name), index);
    }
};

pub const File = struct {
    scopes: std.ArrayList(Scope),

    pub const init: File = .{
        .scopes = .empty,
    };

    pub fn deinit(self: *File, gpa: std.mem.Allocator) void {
        for (self.scopes.items) |*s| s.deinit(gpa);
        self.scopes.deinit(gpa);
    }

    pub fn addScope(
        self: *File,
        gpa: std.mem.Allocator,
        scope: Scope,
    ) error{OutOfMemory}!Scope.Index {
        try self.scopes.append(gpa, scope);
        return std.math.cast(Scope.Index, self.scopes.items.len - 1) orelse
            @panic("Cannot handle file with this many scopes");
    }

    pub fn visitNode(
        self: *File,
        gpa: std.mem.Allocator,
        tree: *Ast,
        scope_index: Scope.Index,
        node_index: Ast.Node.Index,
    ) !void {
        const node_tag = tree.nodeTag(node_index);

        if (symbolNameSlice(tree, node_index)) |name| {
            std.debug.print(
                "Symbol Scope: {d}, Node: {d} {s} {}\n",
                .{ scope_index, node_index, name, node_tag },
            );
            var scope_ref = &self.scopes.items[scope_index];
            try scope_ref.addSymbol(gpa, name, node_index);
        }

        // TODO: Move this logic out into something more self contained about
        // iterating with the concept of scoping without coupled to symbol name
        // resolution.

        // Portions of this switch statement was copied and modified from ZLS.
        // The original ZLS MIT License applies:
        //
        // MIT License
        // Copyright (c) ZLS contributors
        //
        // Permission is hereby granted, free of charge, to any person obtaining a copy
        // of this software and associated documentation files (the "Software"), to deal
        // in the Software without restriction, including without limitation the rights
        // to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        // copies of the Software, and to permit persons to whom the Software is
        // furnished to do so, subject to the following conditions:
        //
        // The above copyright notice and this permission notice shall be included in all
        // copies or substantial portions of the Software.
        //
        // THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        // IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        // FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        // AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        // LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        // OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        // SOFTWARE.
        switch (node_tag) {
            // When we see root (should only ever be once) we simply want to
            // visit all its declarations.
            .root => {
                std.debug.assert(self.scopes.items.len == 0);

                const child_scope_index = try self.addScope(gpa, .init(gpa, node_index, .{}));
                for (tree.rootDecls()) |child| {
                    try self.visitNode(gpa, tree, child_scope_index, child);
                }
            },
            // When we see a block we want to add a new scope and then visit
            // each statement within the block with the new scope.
            .block,
            .block_semicolon,
            .block_two,
            .block_two_semicolon,
            => {
                const child_scope_index = try self.addScope(
                    gpa,
                    .init(gpa, node_index, .{ .parent = scope_index }),
                );

                var buffer: [2]Ast.Node.Index = undefined;
                const children = tree.blockStatements(
                    &buffer,
                    node_index,
                ).?;
                for (children) |child| {
                    try self.visitNode(
                        gpa,
                        tree,
                        child_scope_index,
                        child,
                    );
                }
            },
            .address_of,
            .@"comptime",
            .@"defer",
            .@"nosuspend",
            .@"resume",
            .@"suspend",
            .@"try",
            .bit_not,
            .bool_not,
            .deref,
            .negation,
            .negation_wrap,
            .optional_type,
            => {
                try self.visitNode(gpa, tree, scope_index, tree.nodeData(node_index).node);
            },
            .@"return",
            => {
                if (tree.nodeData(node_index).opt_node.unwrap()) |lhs| {
                    try self.visitNode(gpa, tree, scope_index, lhs);
                }
            },
            .add,
            .add_sat,
            .add_wrap,
            .array_access,
            .array_cat,
            .array_init_one,
            .array_init_one_comma,
            .array_mult,
            .array_type,
            .assign,
            .assign_add,
            .assign_add_sat,
            .assign_add_wrap,
            .assign_bit_and,
            .assign_bit_or,
            .assign_bit_xor,
            .assign_div,
            .assign_mod,
            .assign_mul,
            .assign_mul_sat,
            .assign_mul_wrap,
            .assign_shl,
            .assign_shl_sat,
            .assign_shr,
            .assign_sub,
            .assign_sub_sat,
            .assign_sub_wrap,
            .bang_equal,
            .bit_and,
            .bit_or,
            .bit_xor,
            .bool_and,
            .bool_or,
            .@"catch",
            .container_field_align,
            .div,
            .equal_equal,
            .error_union,
            .greater_or_equal,
            .greater_than,
            .less_or_equal,
            .less_than,
            .merge_error_sets,
            .mod,
            .mul,
            .mul_sat,
            .mul_wrap,
            .@"orelse",
            .shl,
            .shl_sat,
            .shr,
            .sub,
            .sub_sat,
            .sub_wrap,
            .switch_range,
            => {
                const lhs, const rhs = tree.nodeData(node_index).node_and_node;
                try self.visitNode(gpa, tree, scope_index, lhs);
                try self.visitNode(gpa, tree, scope_index, rhs);
            },
            .call_one,
            .call_one_comma,
            .container_field_init,
            .for_range,
            .struct_init_one,
            .struct_init_one_comma,
            => {
                const lhs, const opt_rhs = tree.nodeData(node_index).node_and_opt_node;
                try self.visitNode(gpa, tree, scope_index, lhs);
                if (opt_rhs.unwrap()) |rhs| {
                    try self.visitNode(gpa, tree, scope_index, rhs);
                }
            },
            .array_init_dot_two,
            .array_init_dot_two_comma,
            .builtin_call_two,
            .builtin_call_two_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                const opt_lhs, const opt_rhs = tree.nodeData(node_index).opt_node_and_opt_node;
                if (opt_lhs.unwrap()) |lhs| {
                    try self.visitNode(gpa, tree, scope_index, lhs);
                }
                if (opt_rhs.unwrap()) |rhs| {
                    try self.visitNode(gpa, tree, scope_index, rhs);
                }
            },
            .container_decl_two,
            .container_decl_two_trailing,
            => {
                const child_scope_index = try self.addScope(
                    gpa,
                    .init(gpa, node_index, .{ .parent = scope_index }),
                );

                const opt_lhs, const opt_rhs = tree.nodeData(node_index).opt_node_and_opt_node;
                if (opt_lhs.unwrap()) |lhs| {
                    try self.visitNode(gpa, tree, child_scope_index, lhs);
                }
                if (opt_rhs.unwrap()) |rhs| {
                    try self.visitNode(gpa, tree, child_scope_index, rhs);
                }
            },
            .asm_simple,
            .field_access,
            .grouped_expression,
            .unwrap_optional,
            => {
                try self.visitNode(gpa, tree, scope_index, tree.nodeData(node_index).node_and_token[0]);
            },
            .@"errdefer",
            .test_decl,
            => {
                try self.visitNode(gpa, tree, scope_index, tree.nodeData(node_index).opt_token_and_node[1]);
            },
            .anyframe_type,
            => {
                try self.visitNode(gpa, tree, scope_index, tree.nodeData(node_index).token_and_node[1]);
            },
            .@"break",
            .@"continue",
            => {
                if (tree.nodeData(node_index).opt_token_and_opt_node[1].unwrap()) |rhs| {
                    try self.visitNode(gpa, tree, scope_index, rhs);
                }
            },
            .array_init_dot,
            .array_init_dot_comma,
            .builtin_call,
            .builtin_call_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .tagged_union,
            .tagged_union_trailing,
            => {
                for (tree.extraDataSlice(tree.nodeData(node_index).extra_range, Ast.Node.Index)) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
            },
            .container_decl,
            .container_decl_trailing,
            => {
                const child_scope_index = try self.addScope(
                    gpa,
                    .init(gpa, node_index, .{ .parent = scope_index }),
                );

                for (tree.extraDataSlice(tree.nodeData(node_index).extra_range, Ast.Node.Index)) |child| {
                    try self.visitNode(gpa, tree, child_scope_index, child);
                }
            },
            .aligned_var_decl,
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            => {
                const var_decl = tree.fullVarDecl(node_index).?.ast;
                if (var_decl.type_node.unwrap()) |type_node| try self.visitNode(gpa, tree, scope_index, type_node);
                if (var_decl.align_node.unwrap()) |align_node| try self.visitNode(gpa, tree, scope_index, align_node);
                if (var_decl.addrspace_node.unwrap()) |addrspace_node| try self.visitNode(gpa, tree, scope_index, addrspace_node);
                if (var_decl.section_node.unwrap()) |section_node| try self.visitNode(gpa, tree, scope_index, section_node);
                if (var_decl.init_node.unwrap()) |init_node| try self.visitNode(gpa, tree, scope_index, init_node);
            },
            .assign_destructure => {
                const assign_destructure = tree.assignDestructure(node_index);
                for (assign_destructure.ast.variables) |lhs_node| {
                    try self.visitNode(gpa, tree, scope_index, lhs_node);
                }
                try self.visitNode(gpa, tree, scope_index, assign_destructure.ast.value_expr);
            },
            .array_type_sentinel => {
                const array_type = tree.arrayTypeSentinel(node_index).ast;
                try self.visitNode(gpa, tree, scope_index, array_type.elem_count);
                if (array_type.sentinel.unwrap()) |sentinel| try self.visitNode(gpa, tree, scope_index, sentinel);
                try self.visitNode(gpa, tree, scope_index, array_type.elem_type);
            },
            .ptr_type,
            .ptr_type_aligned,
            .ptr_type_bit_range,
            .ptr_type_sentinel,
            => {
                const ptr_type = tree.fullPtrType(node_index).?.ast;
                if (ptr_type.sentinel.unwrap()) |sentinel| try self.visitNode(gpa, tree, scope_index, sentinel);
                if (ptr_type.align_node.unwrap()) |align_node| try self.visitNode(gpa, tree, scope_index, align_node);
                if (ptr_type.bit_range_start.unwrap()) |bit_range_start| try self.visitNode(gpa, tree, scope_index, bit_range_start);
                if (ptr_type.bit_range_end.unwrap()) |bit_range_end| try self.visitNode(gpa, tree, scope_index, bit_range_end);
                if (ptr_type.addrspace_node.unwrap()) |addrspace_node| try self.visitNode(gpa, tree, scope_index, addrspace_node);
                try self.visitNode(gpa, tree, scope_index, ptr_type.child_type);
            },
            .slice,
            .slice_open,
            .slice_sentinel,
            => {
                const slice = tree.fullSlice(node_index).?;
                try self.visitNode(gpa, tree, scope_index, slice.ast.sliced);
                try self.visitNode(gpa, tree, scope_index, slice.ast.start);
                if (slice.ast.end.unwrap()) |end| try self.visitNode(gpa, tree, scope_index, end);
                if (slice.ast.sentinel.unwrap()) |sentinel| try self.visitNode(gpa, tree, scope_index, sentinel);
            },
            .array_init,
            .array_init_comma,
            => {
                const array_init = tree.arrayInit(node_index).ast;
                if (array_init.type_expr.unwrap()) |type_expr| try self.visitNode(gpa, tree, scope_index, type_expr);
                for (array_init.elements) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
            },
            .struct_init,
            .struct_init_comma,
            => {
                const struct_init = tree.structInit(node_index).ast;
                if (struct_init.type_expr.unwrap()) |type_expr| try self.visitNode(gpa, tree, scope_index, type_expr);
                for (struct_init.fields) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
            },
            .call,
            .call_comma,
            => {
                const call = tree.callFull(node_index).ast;
                try self.visitNode(gpa, tree, scope_index, call.fn_expr);
                for (call.params) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
            },
            .@"switch",
            .switch_comma,
            => {
                const switch_ast = tree.fullSwitch(node_index).?;
                try self.visitNode(gpa, tree, scope_index, switch_ast.ast.condition);
                for (switch_ast.ast.cases) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
            },
            .switch_case,
            .switch_case_one,
            .switch_case_inline_one,
            .switch_case_inline,
            => {
                const switch_case = tree.fullSwitchCase(node_index).?.ast;
                for (switch_case.values) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
                try self.visitNode(gpa, tree, scope_index, switch_case.target_expr);
            },
            .@"while",
            .while_cont,
            .while_simple,
            => {
                const while_ast = tree.fullWhile(node_index).?.ast;
                try self.visitNode(gpa, tree, scope_index, while_ast.cond_expr);
                if (while_ast.cont_expr.unwrap()) |cont_expr| try self.visitNode(gpa, tree, scope_index, cont_expr);
                try self.visitNode(gpa, tree, scope_index, while_ast.then_expr);
                if (while_ast.else_expr.unwrap()) |else_expr| try self.visitNode(gpa, tree, scope_index, else_expr);
            },
            .@"for",
            .for_simple,
            => {
                const for_ast = tree.fullFor(node_index).?.ast;
                for (for_ast.inputs) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
                try self.visitNode(gpa, tree, scope_index, for_ast.then_expr);
                if (for_ast.else_expr.unwrap()) |else_expr| try self.visitNode(gpa, tree, scope_index, else_expr);
            },
            .@"if",
            .if_simple,
            => {
                const if_ast = tree.fullIf(node_index).?.ast;
                try self.visitNode(gpa, tree, scope_index, if_ast.cond_expr);
                try self.visitNode(gpa, tree, scope_index, if_ast.then_expr);
                if (if_ast.else_expr.unwrap()) |else_expr| try self.visitNode(gpa, tree, scope_index, else_expr);
            },
            .fn_decl => {
                try self.visitNode(gpa, tree, scope_index, tree.nodeData(node_index).node_and_node[0]);
                try self.visitNode(gpa, tree, scope_index, tree.nodeData(node_index).node_and_node[1]);
            },
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            => {
                var buffer: [1]Ast.Node.Index = undefined;
                const fn_proto = tree.fullFnProto(&buffer, node_index).?;

                var it = fn_proto.iterate(tree);
                while (it.next()) |param| {
                    try self.visitNode(gpa, tree, scope_index, param.type_expr orelse continue);
                }
                if (fn_proto.ast.align_expr.unwrap()) |align_expr| try self.visitNode(gpa, tree, scope_index, align_expr);
                if (fn_proto.ast.addrspace_expr.unwrap()) |addrspace_expr| try self.visitNode(gpa, tree, scope_index, addrspace_expr);
                if (fn_proto.ast.section_expr.unwrap()) |section_expr| try self.visitNode(gpa, tree, scope_index, section_expr);
                if (fn_proto.ast.callconv_expr.unwrap()) |callconv_expr| try self.visitNode(gpa, tree, scope_index, callconv_expr);
                if (fn_proto.ast.return_type.unwrap()) |return_type| try self.visitNode(gpa, tree, scope_index, return_type);
            },
            .container_decl_arg,
            .container_decl_arg_trailing,
            => {
                const child_scope_index = try self.addScope(
                    gpa,
                    .init(gpa, node_index, .{ .parent = scope_index }),
                );

                const decl = tree.containerDeclArg(node_index).ast;
                if (decl.arg.unwrap()) |arg| try self.visitNode(gpa, tree, scope_index, arg);
                for (decl.members) |child| {
                    try self.visitNode(gpa, tree, child_scope_index, child);
                }
            },
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                const decl = tree.taggedUnionEnumTag(node_index).ast;
                if (decl.arg.unwrap()) |arg| try self.visitNode(gpa, tree, scope_index, arg);
                for (decl.members) |child| {
                    try self.visitNode(gpa, tree, scope_index, child);
                }
            },
            .container_field,
            => {
                const field = tree.containerField(node_index).ast;
                try self.visitNode(gpa, tree, scope_index, field.type_expr.unwrap().?);
                if (field.align_expr.unwrap()) |align_expr| try self.visitNode(gpa, tree, scope_index, align_expr);
                if (field.value_expr.unwrap()) |value_expr| try self.visitNode(gpa, tree, scope_index, value_expr);
            },
            .@"asm",
            .asm_legacy,
            => {
                const asm_node = tree.asmFull(node_index);
                try self.visitNode(gpa, tree, scope_index, asm_node.ast.template);

                for (asm_node.outputs) |output_node| {
                    const has_arrow = tree.tokenTag(tree.nodeMainToken(output_node) + 4) == .arrow;
                    if (has_arrow) {
                        if (tree.nodeData(output_node).opt_node_and_token[0].unwrap()) |lhs| {
                            try self.visitNode(gpa, tree, scope_index, lhs);
                        }
                    }
                }

                for (asm_node.inputs) |input_node| {
                    try self.visitNode(gpa, tree, scope_index, tree.nodeData(input_node).node_and_token[0]);
                }
            },
            .anyframe_literal,
            .asm_input,
            .asm_output,
            .char_literal,
            .enum_literal,
            .error_set_decl,
            .error_value,
            .identifier,
            .multiline_string_literal,
            .number_literal,
            .string_literal,
            .unreachable_literal,
            => {},
        }
        // END OF MODIFIED ZLS CODE.
    }

    /// Returns the name of a node if it's a symbol (e.g, struct field or
    /// variable declaration). Returns null if it's not a symbol.
    fn symbolNameSlice(tree: *Ast, node_index: Ast.Node.Index) ?[]const u8 {
        return if (tree.fullContainerField(node_index)) |field|
            tree.tokenSlice(field.ast.main_token)
        else if (tree.fullVarDecl(node_index)) |decl|
            tree.tokenSlice(decl.ast.mut_token + 1)
        else if (tree.nodeTag(node_index) == .fn_decl)
            tree.tokenSlice(tree.nodeMainToken(node_index) + 1)
        else
            null;
    }
};

pub const SymbolTable = struct {
    gpa: std.mem.Allocator,
    files: std.StringHashMap(File),

    pub fn init(gpa: std.mem.Allocator) SymbolTable {
        return SymbolTable{
            .gpa = gpa,
            .files = .init(gpa),
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.gpa);
            self.gpa.free(entry.key_ptr.*);
        }
        self.files.deinit();
    }

    pub fn consumeFile(
        self: *SymbolTable,
        path: []const u8,
        arena: std.mem.Allocator,
    ) !void {
        if (self.files.contains(path)) return;

        var file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        var file_reader_buffer: [1024]u8 = undefined;
        var file_reader = file.readerStreaming(&file_reader_buffer);

        var buffer: std.io.Writer.Allocating = .init(arena);

        if (file_reader.getSize()) |size| {
            const casted_size = std.math.cast(u32, size) orelse return error.StreamTooLong;
            try buffer.ensureTotalCapacity(casted_size);
        } else |_| {
            // Do nothing.
        }

        _ = try file_reader.interface.streamRemaining(&buffer.writer);

        const contents = try buffer.toOwnedSliceSentinel(0);

        var tree = try std.zig.Ast.parse(arena, contents, .zig);

        try self.files.put(try self.gpa.dupe(u8, path), .init);
        try self.files.getPtr(path).?.visitNode(self.gpa, &tree, 0, .root);
    }
};

const session = @import("session.zig");
const shims = @import("shims.zig");
const std = @import("std");
const testing = @import("testing.zig");
const version = @import("version.zig");
const zls = @import("zls");
const NodeIndexShim = shims.NodeIndexShim;
const Ast = std.zig.Ast;
