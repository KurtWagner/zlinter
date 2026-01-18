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

    queue: std.ArrayList(NodeIndexShim) = .empty,
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
    tree: *const Ast,
    node: Ast.Node.Index,
) error{OutOfMemory}![]Ast.Node.Index {
    var children: std.ArrayList(Ast.Node.Index) = .empty;
    defer children.deinit(gpa);

    var it = zls.ast.Iterator.init(tree, node);
    while (it.next(tree)) |child_node| {
        std.debug.assert(child_node != .root);
        try children.append(gpa, child_node);
    }

    return children.toOwnedSlice(gpa);
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

        const environ_map: std.process.Environ.Map = .init(arena.allocator());

        var context: session.LintContext = undefined;
        try context.init(.{}, std.testing.io, &environ_map, std.testing.allocator, arena.allocator());
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

    const environ_map: std.process.Environ.Map = .init(arena.allocator());

    var context: session.LintContext = undefined;
    try context.init(.{}, std.testing.io, &environ_map, std.testing.allocator, arena.allocator());
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

    const environ_map: std.process.Environ.Map = .init(arena.allocator());

    var context: session.LintContext = undefined;
    try context.init(.{}, std.testing.io, &environ_map, std.testing.allocator, arena.allocator());
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

        const environ_map: std.process.Environ.Map = .init(arena.allocator());

        var context: session.LintContext = undefined;
        try context.init(.{}, std.testing.io, &environ_map, std.testing.allocator, arena.allocator());
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

const session = @import("session.zig");
const shims = @import("shims.zig");
const std = @import("std");
const testing = @import("testing.zig");
const version = @import("version.zig");
const zls = @import("zls");
const NodeIndexShim = shims.NodeIndexShim;
const Ast = std.zig.Ast;
