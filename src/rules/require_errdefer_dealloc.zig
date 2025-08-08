//! > [!WARNING]
//! > The `require_errdefer_dealloc` rule is still under testing and development.
//! > It may not work as expected and may change without notice.
//!
//! Ensure that any allocation made within a function that can return an error
//! is paired with `errdefer`, unless the resource is already being released in
//! a `defer` block.
//!
//! **Why?**
//!
//! If a function returns an error, it's signaling a recoverable condition
//! within the application's normal control flow. Failing to perform cleanup
//! in these cases can lead to memory leaks.
//!
//! **Caveats:**
//!
//! * This rule is not exhaustive. It makes a best-effort attempt to detect known
//!   object declarations that require cleanup, but a complete check is
//!   impractical at this level. It currently only looks at std library containers
//!   like `ArrayList` and `HashMap`.
//!
//! * This rule cannot always reliably detect usage of fixed buffer allocators or
//!   arenas; however, using `errdefer array.deinit(arena);` in these cases is
//!   generally harmless. It will do its best to ignore the most obvious cases.
//!
//! **Example:**
//!
//! ```zig
//! // Bad: On success, returns an owned slice the caller must free; on error, memory is leaked.
//! pub fn message(age: u8, allocator: std.mem.Allocator) error{ OutOfMemory, InvalidAge }![]const u8 {
//!     var parts = std.ArrayList(u8).init(allocator);
//!
//!     try parts.appendSlice("You are ");
//!     if (age > 18)
//!         try parts.appendSlice("an adult")
//!     else if (age > 0)
//!         try parts.appendSlice("not an adult")
//!     else
//!         return error.InvalidAge;
//!
//!     return parts.toOwnedSlice();
//! }
//! ```
//!

/// Config for require_errdefer_dealloc rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the require_errdefer_dealloc rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_errdefer_dealloc),
        .run = &run,
    };
}

/// Runs the require_errdefer_dealloc rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const tree = doc.handle.tree;

    var problem_nodes = std.ArrayList(std.zig.Ast.Node.Index).init(allocator);
    defer problem_nodes.deinit();

    const root: zlinter.shims.NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple;

        var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
        const fn_decl = zlinter.ast.fnDecl(tree, node.toNodeIndex(), &fn_proto_buffer) orelse continue :nodes;

        if (!zlinter.ast.fnProtoReturnsError(tree, fn_decl.proto)) continue :nodes;

        try processBlock(doc, fn_decl.block, &problem_nodes, allocator);
    }

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    for (problem_nodes.items) |node| {
        try lint_problems.append(.{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try std.fmt.allocPrint(allocator, "Missing `errdefer` cleanup", .{}),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(),
        )
    else
        null;
}

fn processBlock(
    doc: zlinter.session.LintDocument,
    block_node: std.zig.Ast.Node.Index,
    problems: *std.ArrayList(std.zig.Ast.Node.Index),
    gpa: std.mem.Allocator,
) !void {
    const tree = doc.handle.tree;

    var cleanup_symbols: std.StringHashMap(std.zig.Ast.Node.Index) = .init(gpa);
    defer {
        var it = cleanup_symbols.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        cleanup_symbols.deinit();
    }

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    for (doc.lineage.items(.children)[zlinter.shims.NodeIndexShim.init(block_node).index] orelse &.{}) |child_node| {
        if (try declRef(doc, child_node)) |decl_ref| {
            if (decl_ref.hasDeinit())
                try cleanup_symbols.put(try gpa.dupe(u8, decl_ref.var_name), child_node);
        } else if (try zlinter.ast.deferBlock(doc, child_node, gpa)) |defer_block| {
            defer defer_block.deinit(gpa);

            for (defer_block.children) |defer_block_child| {
                const cleanup_call = callWithName(doc, defer_block_child, &call_buffer, &.{"deinit"}) orelse continue;
                switch (cleanup_call.kind) {
                    .single_field => |info| {
                        if (cleanup_symbols.fetchRemove(tree.tokenSlice(info.field_main_token))) |e| gpa.free(e.key);
                    },
                    .enum_literal, .other => {},
                }
            }
        } else if (zlinter.ast.isBlock(tree, child_node)) {
            try processBlock(doc, child_node, problems, gpa);
        }
    }

    var leftover_it = cleanup_symbols.valueIterator();
    while (leftover_it.next()) |node| {
        try problems.append(node.*);
    }
}

// TODO(#48): Write unit tests for helpers and consider whether some should be moved to ast

const Call = struct {
    params: []const std.zig.Ast.Node.Index,

    kind: union(enum) {
        /// e.g., `parent.call()` not `parent.child.call()`
        single_field: struct {
            /// e.g., `parent.call()` would have `parent` as the main token here.
            field_main_token: std.zig.Ast.TokenIndex,
            /// e.g., `parent.call()` would have `call` as the identifier token here.
            call_identifier_token: std.zig.Ast.TokenIndex,
        },
        /// array_access, unwrap_optional, nested field_access
        ///
        /// e.g., `parent.child.call()`, `optional.?.call()` and `array[0].call()`
        ///
        /// If there's value this can be broken up in the future but for now we do
        /// not need the separation.
        other: struct {
            /// e.g., `parent.child.call()` would have `call` as the identifier token here.
            call_identifier_token: std.zig.Ast.TokenIndex,
        },
        /// e.g., `.init()`
        enum_literal: struct {
            /// e.g., `.init()` would have `init` here
            call_identifier_token: std.zig.Ast.TokenIndex,
        },
    },
};

/// Returns call information for cases handled by the `require_errdefer_dealloc`
/// Not all calls are handled so this method is not generally useful
fn callWithName(doc: zlinter.session.LintDocument, node: std.zig.Ast.Node.Index, buffer: *[1]std.zig.Ast.Node.Index, comptime names: []const []const u8) ?Call {
    const tree = doc.handle.tree;

    const call = tree.fullCall(buffer, node) orelse return null;

    const fn_expr_node = call.ast.fn_expr;
    const fn_expr_node_data = zlinter.shims.nodeData(tree, fn_expr_node);
    const fn_expr_node_tag = zlinter.shims.nodeTag(tree, fn_expr_node);

    switch (fn_expr_node_tag) {
        // e.g., `parent.*`
        .field_access => {
            const field_node, const fn_name = switch (zlinter.version.zig) {
                .@"0.14" => .{ fn_expr_node_data.lhs, fn_expr_node_data.rhs },
                .@"0.15" => .{ fn_expr_node_data.node_and_token[0], fn_expr_node_data.node_and_token[1] },
            };
            std.debug.assert(zlinter.shims.tokenTag(tree, fn_name) == .identifier);

            var match: bool = false;
            const fn_name_slice = tree.tokenSlice(fn_name);
            for (names) |name| {
                if (std.mem.eql(u8, name, fn_name_slice)) {
                    match = true;
                    break;
                }
            }
            if (!match) return null;

            const field_node_tag = zlinter.shims.nodeTag(tree, field_node);
            if (field_node_tag != .identifier) {
                // e.g, array_access, unwrap_optional, field_access
                return .{
                    .params = call.ast.params,
                    .kind = .{
                        .other = .{
                            .call_identifier_token = fn_name,
                        },
                    },
                };
            }
            // e.g., `parent.call()` not `parent.child.call()`
            return .{
                .params = call.ast.params,
                .kind = .{
                    .single_field = .{
                        .field_main_token = zlinter.shims.nodeMainToken(tree, field_node),
                        .call_identifier_token = fn_name,
                    },
                },
            };
        },
        // e.g., `.init()`
        .enum_literal => {
            const fn_name = zlinter.shims.nodeMainToken(tree, fn_expr_node);
            std.debug.assert(zlinter.shims.tokenTag(tree, fn_name) == .identifier);

            const identfier_slice = tree.tokenSlice(fn_name);
            for (names) |name| {
                if (std.mem.eql(u8, name, identfier_slice)) {
                    return .{
                        .params = call.ast.params,
                        .kind = .{
                            .enum_literal = .{
                                .call_identifier_token = fn_name,
                            },
                        },
                    };
                }
            }
        },
        // .identifier => {},
        else => std.log.debug("callWithName does not handle fn_expr of tag {s}", .{@tagName(fn_expr_node_tag)}),
    }

    return null;
}

const DeclRef = struct {
    var_name: []const u8,
    name: []const u8,
    uri: []const u8,

    const deinit_references = std.StaticStringMap([]const u8).initComptime(.{
        .{ "ArrayHashMap", "std/array_hash_map.zig" },
        .{ "ArrayHashMapUnmanaged", "std/array_hash_map.zig" },
        .{ "ArrayList", "std/array_list.zig" },
        .{ "ArrayListAligned", "std/array_list.zig" },
        .{ "ArrayListAlignedUnmanaged", "std/array_list.zig" },
        .{ "ArrayListUnmanaged", "std/array_list.zig" },
        .{ "AutoArrayHashMap", "std/hash_map.zig" },
        .{ "AutoArrayHashMapUnmanaged", "std/hash_map.zig" },
        .{ "AutoHashMap", "std/hash_map.zig" },
        .{ "AutoHashMapUnmanaged", "std/hash_map.zig" },
        .{ "BufSet", "std/buf_set.zig" },
        .{ "DoublyLinkedList", "std/doubly_linked_list.zig" },
        .{ "EnumArray", "std/enum_array.zig" },
        .{ "EnumIndex", "std/enum_index.zig" },
        .{ "EnumMap", "std/enum_map.zig" },
        .{ "HashMap", "std/hash_map.zig" },
        .{ "HashMapUnmanaged", "std/hash_map.zig" },
        .{ "List", "std/singly_linked_list.zig" },
        .{ "MultiArrayList", "std/multi_array_list.zig" },
        .{ "PriorityDequeue", "std/priority_dequeue.zig" },
        .{ "PriorityQueue", "std/priority_queue.zig" },
        .{ "SinglyLinkedList", "std/singly_linked_list.zig" },
        .{ "StringArrayHashMap", "std/hash_map.zig" },
        .{ "StringArrayHashMapUnmanaged", "std/hash_map.zig" },
        .{ "StringHashMap", "std/hash_map.zig" },
        .{ "StringHashMapUnmanaged", "std/hash_map.zig" },
    });

    fn hasDeinit(self: DeclRef) bool {
        if (deinit_references.get(self.name)) |uri_suffix| {
            return std.mem.endsWith(u8, self.uri, uri_suffix);
        }
        return false;
    }
};

fn declRef(doc: zlinter.session.LintDocument, var_decl_node: std.zig.Ast.Node.Index) !?DeclRef {
    const var_decl = doc.handle.tree.fullVarDecl(var_decl_node) orelse return null;

    const init_node = zlinter.shims.NodeIndexShim.initOptional(var_decl.ast.init_node) orelse return null;

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (!switch (zlinter.shims.nodeTag(doc.handle.tree, init_node.toNodeIndex())) {
        .field_access => zlinter.ast.isFieldVarAccess(doc.handle.tree, init_node.toNodeIndex(), &.{"empty"}),
        .enum_literal => zlinter.ast.isEnumLiteral(doc.handle.tree, init_node.toNodeIndex(), &.{"empty"}),
        else =>
        // This will also handle optional and array accesses, which shouldn't occur
        // but shouldn't be a problem to us anyway as we do strict checks on the
        // type anyway.
        //
        // e.g., `array[0].init()` and `optional.?.init()`
        if (callWithName(doc, init_node.toNodeIndex(), &call_buffer, &.{"init"})) |call|
            !hasArenaParam(doc, call.params)
        else
            false,
    }) return null;

    const var_decl_type = try doc.resolveTypeOfNode(var_decl_node) orelse return null;
    switch (var_decl_type.data) {
        .container => |container| {
            const scope_handle = switch (zlinter.version.zig) {
                .@"0.14" => container,
                .@"0.15" => container.scope_handle,
            };
            const node = scope_handle.toNode();
            const tag = zlinter.shims.nodeTag(scope_handle.handle.tree, node);
            switch (tag) {
                .container_decl,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .container_decl_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                => {
                    const tree = scope_handle.handle.tree;
                    const first_token = tree.firstToken(node);

                    // `Foo = struct`
                    if (first_token > 1 and tree.tokens.items(.tag)[first_token - 2] == .identifier and tree.tokens.items(.tag)[first_token - 1] == .equal) {
                        var str_token = first_token - 2;
                        // `Foo: type = struct`
                        if (first_token > 3 and tree.tokens.items(.tag)[first_token - 4] == .identifier and tree.tokens.items(.tag)[first_token - 3] == .colon) {
                            str_token = first_token - 4;
                        }
                        return .{
                            .var_name = doc.handle.tree.tokenSlice(var_decl.ast.mut_token + 1),
                            .name = tree.tokenSlice(str_token),
                            .uri = scope_handle.handle.uri,
                        };
                    } else if (first_token > 0 and tree.tokens.items(.tag)[first_token - 1] == .keyword_return) {
                        const doc_scope = try scope_handle.handle.getDocumentScope();

                        const function_scope = switch (zlinter.version.zig) {
                            .@"0.14" => zlinter.zls.Analyser.innermostFunctionScopeAtIndex(
                                doc_scope,
                                tree.tokens.items(.start)[first_token - 1],
                            ).unwrap(),
                            .@"0.15" => zlinter.zls.Analyser.innermostScopeAtIndexWithTag(
                                doc_scope,
                                tree.tokenStart(first_token - 1),
                                .initOne(.function),
                            ).unwrap(),
                        } orelse return null;

                        var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
                        const func = tree.fullFnProto(&fn_proto_buffer, doc_scope.getScopeAstNode(function_scope).?).?;

                        return .{
                            .var_name = doc.handle.tree.tokenSlice(var_decl.ast.mut_token + 1),
                            .name = tree.tokenSlice(func.name_token orelse return null),
                            .uri = scope_handle.handle.uri,
                        };
                    }
                },
                else => {},
            }
        },
        else => {},
    }

    return null;
}

/// Returns true if it looks like based on parameters that the given call use
/// leveraging an arena like allocator and thus should be excluded from checks
/// by `require_errdefer_dealloc`.
///
/// For example, `.init(arena.allocator())` or `.init(arena)` look like they're
/// accepting an arena so requiring cleanup in `errdefer` is not strictly necessary
/// and may even cause confuion.
///
/// Where as `.init(allocator)` or `.init(std.heap.c_allocator)` should be checked
/// for stricter cleanup on error as it won't automatically clear itself.
fn hasArenaParam(doc: zlinter.session.LintDocument, params: []const std.zig.Ast.Node.Index) bool {
    const tree = doc.handle.tree;
    const skip_var_and_field_names: []const []const u8 = &.{
        "arena",
        "fba",
        "fixed_buffer_allocator",
        "arena_allocator",
    };
    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    for (params) |param_node| {
        const tag = zlinter.shims.nodeTag(tree, param_node);
        switch (tag) {
            .identifier => {
                const slice = tree.tokenSlice(zlinter.shims.nodeMainToken(tree, param_node));
                for (skip_var_and_field_names) |str| {
                    if (std.mem.eql(u8, slice, str)) return true;
                }
            },
            .field_access => if (zlinter.ast.isFieldVarAccess(tree, param_node, skip_var_and_field_names)) return true,
            else => if (callWithName(doc, param_node, &call_buffer, &.{"allocator"})) |call| {
                switch (call.kind) {
                    // e.g., checking for `arena.allocator()` call. Unfortunately
                    // currently won't capture deeply nested, like `parent.arena.allocator()`
                    // but this seems super unlikely so who cares for a linter...
                    .single_field => |info| {
                        for (skip_var_and_field_names) |str|
                            if (std.mem.eql(u8, tree.tokenSlice(info.field_main_token), str)) return true;
                    },
                    .enum_literal, .other => {},
                }
            },
        }
    }
    return false;
}

test "hasArenaParam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    inline for (&.{
        .{
            \\ var a = .init();
            ,
            false,
        },
        .{
            \\ var a = .init(allocator);
            ,
            false,
        },
        .{
            \\ var a = .init(std.heap.c_allocator);
            ,
            false,
        },
        .{
            \\ var a = .init(gpa);
            ,
            false,
        },
        .{
            \\ var a = .init(arena);
            ,
            true,
        },
        .{
            \\ var a = .init(arena_allocator);
            ,
            true,
        },
        .{
            \\ var a = .init(fixed_buffer_allocator);
            ,
            true,
        },
        .{
            \\ var a = .init(fba);
            ,
            true,
        },
        .{
            \\ var a = .init(arena.allocator());
            ,
            true,
        },
        .{
            \\ var a = .init(fba.allocator());
            ,
            true,
        },
        .{
            \\ var a = .init(fixed_buffer_allocator.allocator());
            ,
            true,
        },
    }) |tuple| {
        const source, const expected = tuple;
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        defer _ = arena.reset(.retain_capacity);

        var ctx: zlinter.session.LintContext = undefined;
        try ctx.init(.{}, std.testing.allocator);
        defer ctx.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var doc = (try zlinter.testing.loadFakeDocument(
            &ctx,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        )).?;
        defer doc.deinit(ctx.gpa);

        const tree = doc.handle.tree;
        const actual = hasArenaParam(
            doc,
            tree.fullCall(&buffer, try zlinter.testing.expectNodeOfTagFirst(
                doc,
                &.{
                    .call,
                    .call_comma,
                    .call_one,
                    .call_one_comma,
                },
            )).?.ast.params,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
