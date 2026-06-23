//! AST navigation helpers

pub const ChildIterator = @import("ast/iterator.zig").ChildIterator;
pub const nodeChildrenAlloc = @import("ast/iterator.zig").nodeChildrenAlloc;

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

    current: Ast.Node.Index,
    lineage: *const NodeLineage,
    done: bool = false,

    pub fn next(self: *Self) ?Ast.Node.Index {
        if (self.done or self.current == .root) return null;

        const parent = self.lineage.items(.parent)[@intFromEnum(self.current)];
        if (parent) |p| {
            self.current = p;
            return p;
        } else {
            self.done = true;
            return null;
        }
    }
};

pub const NodeLineageIterator = struct {
    const Self = @This();

    queue: std.ArrayList(Ast.Node.Index) = .empty,
    lineage: *const NodeLineage,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *NodeLineageIterator) void {
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    pub fn next(self: *Self) error{OutOfMemory}!?struct { Ast.Node.Index, NodeConnections } {
        if (self.queue.pop()) |node| {
            const connections = self.lineage.get(@intFromEnum(node));
            for (connections.children orelse &.{}) |child| {
                try self.queue.append(self.gpa, child);
            }
            return .{ node, connections };
        }
        return null;
    }
};

/// `errdefer` and `defer` calls
pub const DeferBlock = struct {
    children: []const Ast.Node.Index,

    pub fn deinit(self: DeferBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.children);
    }
};

pub fn deferBlock(doc: *const session.LintDocument, file_store: *const FileStore, node: Ast.Node.Index, allocator: std.mem.Allocator) !?DeferBlock {
    const zone = tracy.traceNamed(@src(), "ast.deferBlock");
    defer zone.end();

    const tree = file_store.fileTree(doc.file_id);

    const data = tree.nodeData(node);
    const exp_node =
        switch (tree.nodeTag(node)) {
            .@"errdefer" => data.node,
            .@"defer" => data.node,
            else => return null,
        };

    if (isBlock(tree, exp_node)) {
        return .{ .children = try allocator.dupe(Ast.Node.Index, doc.lineage.items(.children)[@intFromEnum(exp_node)] orelse &.{}) };
    } else {
        return .{ .children = try allocator.dupe(Ast.Node.Index, &.{exp_node}) };
    }
}

pub fn isBlock(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => true,
        else => false,
    };
}

/// Returns true if identifier node and itentifier node has the given kind.
pub fn isIdentiferKind(
    tree: Ast,
    node: Ast.Node.Index,
    kind: enum { type },
) bool {
    return switch (tree.nodeTag(node)) {
        .identifier => switch (kind) {
            .type => std.mem.eql(u8, "type", tree.tokenSlice(tree.nodeMainToken(node))),
        },
        else => false,
    };
}

/// Returns true if the node is a builtin call.
pub fn isBuiltinCall(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => true,
        else => false,
    };
}

/// Returns true if the node is a builtin call with the given name.
pub fn isBuiltinCallNamed(tree: Ast, node: Ast.Node.Index, name: []const u8) bool {
    return isBuiltinCall(tree, node) and
        std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), name);
}

test "isBuiltinCall - matches builtin call node kinds" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const value = @import("std");
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const node = try testing.expectSingleNodeOfTag(tree, &.{.builtin_call_two});
    try std.testing.expect(isBuiltinCall(tree, node));
}

test "isBuiltinCallNamed - matches builtin call name" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const value = @typeInfo(u8);
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const node = try testing.expectSingleNodeOfTag(tree, &.{.builtin_call_two});
    try std.testing.expect(isBuiltinCallNamed(tree, node, "@typeInfo"));
}

test "isBuiltinCallNamed - rejects other builtin names" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const value = @sizeOf(u8);
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const node = try testing.expectSingleNodeOfTag(tree, &.{.builtin_call_two});
    try std.testing.expect(!isBuiltinCallNamed(tree, node, "@typeInfo"));
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
        switch (tree.nodeTag(current)) {
            .unwrap_optional => if (options.unwrap_optional_unwrap) {
                current = tree.nodeData(current).node_and_token.@"0";
            } else break,
            .optional_type => if (options.unwrap_optional) {
                current = tree.nodeData(current).node;
            } else break,
            .ptr_type_aligned,
            .ptr_type_sentinel,
            => if (options.unwrap_pointer) {
                current = tree.nodeData(current).opt_node_and_node.@"1";
            } else break,
            .ptr_type,
            => if (options.unwrap_pointer) {
                current = tree.nodeData(current).extra_and_node.@"1";
            } else break,
            else => break,
        }
    }
    return current;
}

/// Returns true if two non-root nodes are overlapping.
///
/// This can be useful if you have a node and want to work out where it's
/// contained (e.g., within a struct).
pub fn isNodeOverlapping(
    tree: Ast,
    a: Ast.Node.Index,
    b: Ast.Node.Index,
) bool {
    std.debug.assert(a != .root);
    std.debug.assert(b != .root);

    const span_a = tree.nodeToSpan(a);
    const span_b = tree.nodeToSpan(b);

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
        if (tree.nodeTag(member).isContainerField()) return false;
    }
    return true;
}

/// Returns true when a node is a direct member of the container API.
///
/// This includes declarations whose direct parent is the root node or a
/// container declaration node, and excludes locals nested inside blocks and
/// statement bodies.
pub fn isContainerMember(tree: Ast, connections: NodeConnections) bool {
    const parent = connections.parent orelse return false;
    if (parent == .root) return true;

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    return tree.fullContainerDecl(&container_decl_buffer, parent) != null;
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
            \\errdefer me.deinit();
            ,
            &.{"me.deinit()"},
        },
    }) |tuple| {
        const source, const expected = tuple;

        defer _ = arena.reset(.retain_capacity);

        var context = testing.initFakeContext(arena.allocator(), std.testing.io);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        );
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        const decl_ref = try deferBlock(
            doc,
            &context.file_store,
            try testing.expectSingleNodeOfTag(doc.tree(&context), &.{ .@"defer", .@"errdefer" }),
            std.testing.allocator,
        );
        defer if (decl_ref) |d| d.deinit(std.testing.allocator);

        try testing.expectNodeSlices(expected, doc.tree(&context), decl_ref.?.children);
    }
}

/// Returns true if return type is `!type` or `error{ErrorName}!type` or `ErrorName!type`
pub fn fnProtoReturnsError(tree: Ast, fn_proto: Ast.full.FnProto) bool {
    const return_node = fn_proto.ast.return_type.unwrap() orelse return false;
    const tag = tree.nodeTag(return_node);
    return switch (tag) {
        .error_union => true,
        else => tree.tokens.items(.tag)[tree.firstToken(return_node) - 1] == .bang,
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
    switch (tree.nodeTag(node)) {
        .fn_decl => {
            const data = tree.nodeData(node);
            const lhs, const rhs = .{ data.node_and_node[0], data.node_and_node[1] };
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
    if (tree.nodeTag(node) != .field_access) return null;

    const last_token = tree.lastToken(node);
    const last_token_tag = tree.tokenTag(last_token);

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
    else switch (tree.nodeTag(node)) {
        .@"catch" => .{ .@"catch" = tree.nodeData(node).node_and_node[1] },
        .@"defer" => .{ .@"defer" = tree.nodeData(node).node },
        .@"errdefer" => .{ .@"errdefer" = tree.nodeData(node).node },
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
            tree.fullVarDecl(try testing.expectSingleNodeOfTag(
                tree,
                &.{
                    .local_var_decl,
                    .global_var_decl,
                    .simple_var_decl,
                    .aligned_var_decl,
                },
            )).?.ast.init_node.unwrap().?,
            names,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

/// Returns true if enum literal matching a given var name
pub fn isEnumLiteral(tree: Ast, node: Ast.Node.Index, enum_names: []const []const u8) bool {
    if (tree.nodeTag(node) != .enum_literal) return false;

    const actual_enum_name = tree.tokenSlice(tree.nodeMainToken(node));
    for (enum_names) |enum_name| {
        if (std.mem.eql(u8, actual_enum_name, enum_name)) return true;
    }
    return false;
}

pub const EnumInfo = struct {
    tags: []const []const u8,
    is_non_exhaustive: bool,

    pub fn deinit(self: *EnumInfo, gpa: std.mem.Allocator) void {
        gpa.free(self.tags);
        self.* = undefined;
    }
};

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
            tree.fullVarDecl(try testing.expectSingleNodeOfTag(
                tree,
                &.{
                    .local_var_decl,
                    .global_var_decl,
                    .simple_var_decl,
                    .aligned_var_decl,
                },
            )).?.ast.init_node.unwrap().?,
            names,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

/// Checks whether the current node is a function call or contains one in its
/// children matching given case sensitive names.
pub fn findFnCall(
    doc: *const session.LintDocument,
    file_store: *const FileStore,
    node: Ast.Node.Index,
    call_buffer: *[1]Ast.Node.Index,
    names: []const []const u8,
) ?FnCall {
    const zone = tracy.traceNamed(@src(), "ast.findFnCall");
    defer zone.end();

    std.debug.assert(names.len > 0);

    if (fnCall(
        doc,
        file_store,
        node,
        call_buffer,
        names,
    )) |call| {
        return call;
    }

    for (doc.lineage.items(.children)[@intFromEnum(node)] orelse &.{}) |child| {
        if (findFnCall(
            doc,
            file_store,
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
    file_store: *const FileStore,
    node: Ast.Node.Index,
    buffer: *[1]Ast.Node.Index,
    names: []const []const u8,
) ?FnCall {
    const zone = tracy.traceNamed(@src(), "ast.fnCall");
    defer zone.end();

    const tree = file_store.fileTree(doc.file_id);
    const call = tree.fullCall(buffer, node) orelse return null;

    const fn_expr_node = call.ast.fn_expr;
    const fn_expr_node_data = tree.nodeData(fn_expr_node);
    const fn_expr_node_tag = tree.nodeTag(fn_expr_node);

    const maybe_fn_call: ?FnCall = maybe_fn_call: {
        switch (fn_expr_node_tag) {
            // e.g., `parent.*`
            .field_access => {
                const field_node, const fn_name = .{ fn_expr_node_data.node_and_token[0], fn_expr_node_data.node_and_token[1] };
                std.debug.assert(tree.tokenTag(fn_name) == .identifier);

                const field_node_tag = tree.nodeTag(field_node);
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
                            .field_main_token = tree.nodeMainToken(field_node),
                        },
                    },
                };
            },
            // e.g., `.init()`
            .enum_literal => {
                const fn_name = tree.nodeMainToken(fn_expr_node);
                std.debug.assert(tree.tokenTag(fn_name) == .identifier);

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
                    .call_identifier_token = tree.nodeMainToken(fn_expr_node),
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
        const fn_name_slice = tree.tokenSlice(fn_call.call_identifier_token);
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

    var context = testing.initFakeContext(arena.allocator(), std.testing.io);
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
        doc.tree(&context),
        &.{ .call, .call_comma, .call_one, .call_one_comma },
    );
    var buffer: [1]Ast.Node.Index = undefined;
    const call = fnCall(
        doc,
        &context.file_store,
        fn_node,
        &buffer,
        &.{},
    ).?;

    try std.testing.expectEqualDeep(&.{}, call.params);
    try std.testing.expectEqualStrings(
        "call",
        doc.tree(&context).tokenSlice(call.call_identifier_token),
    );
    try std.testing.expectEqualStrings("direct", @tagName(call.kind));
}

test "fnCall - single field call with params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var context = testing.initFakeContext(arena.allocator(), std.testing.io);
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
        doc.tree(&context),
        &.{ .call, .call_comma, .call_one, .call_one_comma },
    );
    var buffer: [1]Ast.Node.Index = undefined;
    const call = fnCall(
        doc,
        &context.file_store,
        fn_node,
        &buffer,
        &.{},
    ).?;

    try std.testing.expectEqual(2, call.params.len);
    try std.testing.expectEqualStrings("1", doc.tree(&context).getNodeSource(call.params[0]));
    try std.testing.expectEqualStrings("abc", doc.tree(&context).getNodeSource(call.params[1]));
    try std.testing.expectEqualStrings(
        "single",
        doc.tree(&context).tokenSlice(call.kind.single_field.field_main_token),
    );
    try std.testing.expectEqualStrings(
        "fnName",
        doc.tree(&context).tokenSlice(call.call_identifier_token),
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

        var context = testing.initFakeContext(arena.allocator(), std.testing.io);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            source,
            arena.allocator(),
        );
        errdefer std.debug.print("Failed source: '{s}'\n", .{source});

        var buffer: [1]Ast.Node.Index = undefined;

        try std.testing.expectEqualStrings(
            "fnName",
            doc.tree(&context).tokenSlice(findFnCall(
                doc,
                &context.file_store,
                .root,
                &buffer,
                &.{"fnName"},
            ).?.call_identifier_token),
        );

        try std.testing.expectEqual(
            null,
            findFnCall(
                doc,
                &context.file_store,
                .root,
                &buffer,
                &.{ "fn", "Name", "fnname" },
            ),
        );
    }
}

/// Returns the explicit type node for a declaration node.
pub fn declTypeNode(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.Node.Index {
    if (tree.fullVarDecl(node)) |var_decl| return var_decl.ast.type_node.unwrap();
    if (tree.fullContainerField(node)) |field| return field.ast.type_expr.unwrap();

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buffer, node)) |fn_proto| return fn_proto.ast.return_type.unwrap();

    return null;
}

test "declTypeNode - var declaration returns explicit type" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "const typed: u32 = 1;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const var_decl = try testing.expectVarDecl(tree, "typed");
    const type_node = declTypeNode(tree, var_decl).?;
    try std.testing.expectEqualStrings("u32", tree.getNodeSource(type_node));
}

test "declTypeNode - var declaration without explicit type returns null" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "const inferred = 2;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const var_decl = try testing.expectVarDecl(tree, "inferred");
    try std.testing.expectEqual(null, declTypeNode(tree, var_decl));
}

test "declTypeNode - function declaration returns return type" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\fn named() bool {
        \\    return true;
        \\}
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const fn_decl = try testing.expectSingleNodeOfTag(tree, &.{.fn_decl});
    const type_node = declTypeNode(tree, fn_decl).?;
    try std.testing.expectEqualStrings("bool", tree.getNodeSource(type_node));
}

test "declTypeNode - container field returns explicit type" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const S = struct {
        \\    field: i32,
        \\};
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const field = try testing.expectSingleNodeOfTag(
        tree,
        &.{ .container_field_init, .container_field_align, .container_field },
    );
    const type_node = declTypeNode(tree, field).?;
    try std.testing.expectEqualStrings("i32", tree.getNodeSource(type_node));
}

test "declTypeNode - container field with default returns explicit type" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const S = struct {
        \\    defaulted: u16 = 3,
        \\};
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const field = try testing.expectSingleNodeOfTag(tree, &.{.container_field_init});
    const type_node = declTypeNode(tree, field).?;
    try std.testing.expectEqualStrings("u16", tree.getNodeSource(type_node));
}

test "declTypeNode - function type value is not a declaration type" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "const Callback = fn (u8) void;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const var_decl = try testing.expectVarDecl(tree, "Callback");
    try std.testing.expectEqual(null, declTypeNode(tree, var_decl));
}

/// Returns the identifier token that names a declaration node.
pub fn declNameToken(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?std.zig.Ast.TokenIndex {
    return switch (tree.nodeTag(node)) {
        // Main token is name
        .container_field_init,
        .container_field_align,
        .container_field,
        => tree.nodeMainToken(node),
        // Main token is mutation (e.g., var or const)
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        => tree.nodeMainToken(node) + 1,
        // Main token is "fn"
        .fn_decl,
        => tree.nodeMainToken(node) + 1,
        // Main token may be a name identifier
        .fn_proto_simple,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto,
        => {
            const token = tree.nodeMainToken(node) + 1;
            return switch (tree.tokenTag(token)) {
                .identifier => token,
                else => null,
            };
        },
        else => null,
    };
}

test "declNameToken - var declaration returns identifier token" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "const typed: u32 = 1;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const var_decl = try testing.expectVarDecl(tree, "typed");
    const name_token = declNameToken(tree, var_decl).?;
    try std.testing.expectEqualStrings("typed", tree.tokenSlice(name_token));
}

test "declNameToken - function declaration returns identifier token" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "fn named() void {}",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const fn_decl = try testing.expectSingleNodeOfTag(tree, &.{.fn_decl});
    const name_token = declNameToken(tree, fn_decl).?;
    try std.testing.expectEqualStrings("named", tree.tokenSlice(name_token));
}

test "declNameToken - function prototype returns identifier token" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "extern fn named() void;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const fn_proto = try testing.expectSingleNodeOfTag(
        tree,
        &.{ .fn_proto_simple, .fn_proto_multi, .fn_proto_one, .fn_proto },
    );
    const name_token = declNameToken(tree, fn_proto).?;
    try std.testing.expectEqualStrings("named", tree.tokenSlice(name_token));
}

test "declNameToken - container field returns identifier token" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const S = struct {
        \\    field: i32,
        \\};
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const field = try testing.expectSingleNodeOfTag(
        tree,
        &.{ .container_field_init, .container_field_align, .container_field },
    );
    const name_token = declNameToken(tree, field).?;
    try std.testing.expectEqualStrings("field", tree.tokenSlice(name_token));
}

test "declNameToken - container field with default returns identifier token" {
    var tree = try Ast.parse(
        std.testing.allocator,
        \\const S = struct {
        \\    defaulted: u16 = 3,
        \\};
    ,
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const field = try testing.expectSingleNodeOfTag(tree, &.{.container_field_init});
    const name_token = declNameToken(tree, field).?;
    try std.testing.expectEqualStrings("defaulted", tree.tokenSlice(name_token));
}

test "declNameToken - anonymous function type returns null" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "const Callback = fn (u8) void;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    const var_decl = try testing.expectVarDecl(tree, "Callback");
    const anonymous_fn_type = tree.fullVarDecl(var_decl).?.ast.init_node.unwrap().?;
    try std.testing.expectEqual(null, declNameToken(tree, anonymous_fn_type));
}

test "declNameToken - non declaration returns null" {
    var tree = try Ast.parse(
        std.testing.allocator,
        "const typed: u32 = 1;",
        .zig,
    );
    defer tree.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, declNameToken(tree, .root));
}

const session = @import("session.zig");
const std = @import("std");
const testing = @import("testing.zig");
const tracy = @import("tracy");
const Ast = std.zig.Ast;
const FileStore = @import("session/FileStore.zig");

test {
    std.testing.refAllDecls(@This());
}
