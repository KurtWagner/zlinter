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
//! Caveats:
//!
//! * This rule is not exhaustive. It makes a best-effort attempt to detect known
//!   object declarations that require cleanup, but a complete check is
//!   impractical at this level. It currently only looks at std library containers
//!   like `ArrayList` and `HashMap`.
//!
//! * This rule cannot reliably detect usage of fixed buffer allocators or
//!   arenas; however, using errdefer `array.deinit(arena);` in these cases is
//!   generally harmless.
//!

// TODO(#48): Add integration tests

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
        const fn_decl = fnDecl(tree, node.toNodeIndex(), &fn_proto_buffer) orelse continue :nodes;

        if (!fnProtoReturnsError(tree, fn_decl.proto)) continue :nodes;

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

    for (doc.lineage.items(.children)[zlinter.shims.NodeIndexShim.init(block_node).index] orelse &.{}) |child_node| {
        if (try declRef(doc, child_node)) |decl_ref| {
            if (decl_ref.hasDeinit())
                try cleanup_symbols.put(try gpa.dupe(u8, decl_ref.var_name), child_node);
        } else if (try deferBlock(doc, child_node, gpa)) |defer_block| {
            defer defer_block.deinit(gpa);

            for (defer_block.children) |defer_block_child| {
                const cleanup_call = isFieldCall(doc, defer_block_child, &.{"deinit"}) orelse continue;
                if (cleanup_symbols.fetchRemove(cleanup_call.symbol)) |e| gpa.free(e.key);
            }
        } else if (isBlock(tree, child_node)) {
            try processBlock(doc, child_node, problems, gpa);
        }
    }

    var leftover_it = cleanup_symbols.valueIterator();
    while (leftover_it.next()) |node| {
        try problems.append(node.*);
    }
}

// TODO(#48): Write unit tests for helpers and consider whether some should be moved to ast

const FieldCall = struct {
    symbol: []const u8,
};

fn isFieldCall(doc: zlinter.session.LintDocument, node: std.zig.Ast.Node.Index, comptime names: []const []const u8) ?FieldCall {
    const tree = doc.handle.tree;

    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;

    const data = zlinter.shims.nodeData(tree, call.ast.fn_expr);

    // We only care about field access calls (e.g., calling `deinit` on an object)
    // Otherwise calls can also be identifiers!
    if (zlinter.shims.nodeTag(tree, call.ast.fn_expr) != .field_access) return null;

    const field_node, const field_name = switch (zlinter.version.zig) {
        .@"0.14" => .{ data.lhs, data.rhs },
        .@"0.15" => .{ data.node_and_token[0], data.node_and_token[1] },
    };

    if (zlinter.shims.nodeTag(tree, field_node) != .identifier) return null;

    const field_name_slice = tree.tokenSlice(field_name);
    var matches = false;
    for (names) |name| {
        if (std.mem.eql(u8, name, field_name_slice)) {
            matches = true;
            break;
        }
    }
    if (!matches) return null;

    return .{ .symbol = tree.tokenSlice(zlinter.shims.nodeMainToken(tree, field_node)) };
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

    // TODO(#48): Cleanup this hackfest which is tightly coupled to std containers
    // that are unmanaged (for empty) and managed calls with init(allocator).
    if (zlinter.shims.nodeTag(doc.handle.tree, init_node.toNodeIndex()) == .field_access) {
        const value = doc.handle.tree.tokenSlice(doc.handle.tree.lastToken(init_node.toNodeIndex()));
        if (!std.mem.eql(u8, value, "empty")) {
            return null;
        }
    } else if (zlinter.shims.nodeTag(doc.handle.tree, init_node.toNodeIndex()) == .enum_literal) {
        const value = doc.handle.tree.tokenSlice(zlinter.shims.nodeMainToken(doc.handle.tree, init_node.toNodeIndex()));
        if (!std.mem.eql(u8, value, "empty")) {
            return null;
        }
    } else {
        var call_buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (doc.handle.tree.fullCall(&call_buffer, init_node.toNodeIndex())) |call_fn| {
            if (zlinter.shims.nodeTag(doc.handle.tree, call_fn.ast.fn_expr) == .field_access) {
                if (!std.mem.eql(u8, doc.handle.tree.tokenSlice(doc.handle.tree.lastToken(call_fn.ast.fn_expr)), "init")) {
                    return null;
                }
            } else {
                return null;
            }
        } else {
            return null;
        }
    }

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

const FnDecl = struct {
    proto: std.zig.Ast.full.FnProto,
    block: std.zig.Ast.Node.Index,
};

/// Returns the function declaration (proto and block) if node is a function declaration,
/// otherwise returns null.
fn fnDecl(tree: std.zig.Ast, node: std.zig.Ast.Node.Index, fn_proto_buffer: *[1]std.zig.Ast.Node.Index) ?FnDecl {
    switch (zlinter.shims.nodeTag(tree, node)) {
        .fn_decl => {
            const data = zlinter.shims.nodeData(tree, node);
            const lhs, const rhs = switch (zlinter.version.zig) {
                .@"0.14" => .{ data.lhs, data.rhs },
                .@"0.15" => .{ data.node_and_node[0], data.node_and_node[1] },
            };
            return .{ .proto = tree.fullFnProto(fn_proto_buffer, lhs).?, .block = rhs };
        },
        else => return null,
    }
}

/// Returns true if return type is `!type` or `error{ErrorName}!type` or `ErrorName!type`
fn fnProtoReturnsError(tree: std.zig.Ast, fn_proto: std.zig.Ast.full.FnProto) bool {
    const return_node = zlinter.shims.NodeIndexShim.initOptional(fn_proto.ast.return_type) orelse return false;
    const tag = zlinter.shims.nodeTag(tree, return_node.toNodeIndex());
    return switch (tag) {
        .error_union => true,
        else => tree.tokens.items(.tag)[tree.firstToken(return_node.toNodeIndex()) - 1] == .bang,
    };
}

/// `errdefer` and `defer` calls
const DeferBlock = struct {
    children: []const std.zig.Ast.Node.Index,

    fn deinit(self: DeferBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.children);
    }
};

fn deferBlock(doc: zlinter.session.LintDocument, node: std.zig.Ast.Node.Index, allocator: std.mem.Allocator) !?DeferBlock {
    const tree = doc.handle.tree;

    const data = zlinter.shims.nodeData(tree, node);
    const exp_node =
        switch (zlinter.shims.nodeTag(tree, node)) {
            .@"errdefer" => switch (zlinter.version.zig) {
                .@"0.14" => data.rhs,
                .@"0.15" => data.opt_token_and_node[1],
            },
            .@"defer" => switch (zlinter.version.zig) {
                .@"0.14" => data.rhs,
                .@"0.15" => data.node,
            },
            else => return null,
        };

    if (isBlock(tree, exp_node)) {
        return .{ .children = try allocator.dupe(std.zig.Ast.Node.Index, doc.lineage.items(.children)[zlinter.shims.NodeIndexShim.init(exp_node).index] orelse &.{}) };
    } else {
        return .{ .children = try allocator.dupe(std.zig.Ast.Node.Index, &.{exp_node}) };
    }
}

fn isBlock(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (zlinter.shims.nodeTag(tree, node)) {
        .block_two, .block_two_semicolon, .block, .block_semicolon => true,
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
