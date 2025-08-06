//! Ensure that any allocation made within a function that can return an error
//! is paired with errdefer, unless the resource is already being released in a
//! defer block.
//!
//! This rule is not exhaustive. It makes a best-effort attempt to detect known
//! object declarations that require cleanup, but a complete check is
//! impractical at this level.

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
    _ = config;
    _ = rule;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    const tree = doc.handle.tree;

    const root: zlinter.shims.NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple;

        var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
        const fn_decl = fnDecl(tree, node.toNodeIndex(), &fn_proto_buffer) orelse continue :nodes;

        if (!fnProtoReturnsError(tree, fn_decl.proto)) continue :nodes;

        for (doc.lineage.items(.children)[fn_decl.block] orelse &.{}) |child_node| {
            // TODO: Nested block
            if (try declRef(doc, child_node)) |decl_ref| {
                if (decl_ref.hasDeinit())
                    std.debug.print("Reference: {s} {s}\n", .{ decl_ref.name, decl_ref.uri });
            } else if (deferBlock(doc, child_node)) |defer_block| {
                for (defer_block.children) |defer_block_child| {
                    std.debug.print("Defer - {s}\n", .{tree.getNodeSource(defer_block_child)});
                }
            } else {
                const tag = zlinter.shims.nodeTag(tree, child_node);
                switch (tag) {
                    .@"errdefer", .@"defer" => {},
                    else => {},
                }
            }
        }
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

const DeclRef = struct {
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
    switch (doc.handle.tree.nodes.items(.tag)[var_decl_node]) {
        .global_var_decl, .local_var_decl, .aligned_var_decl, .simple_var_decl => {},
        else => return null,
    }

    const var_decl_type = try doc.analyser.resolveTypeOfNode(.{ .handle = doc.handle, .node = var_decl_node }) orelse return null;

    switch (var_decl_type.data) {
        .container => |scope_handle| {
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
                            .name = tree.tokenSlice(str_token),
                            .uri = scope_handle.handle.uri,
                        };
                    } else if (first_token > 0 and tree.tokens.items(.tag)[first_token - 1] == .keyword_return) {
                        const doc_scope = try scope_handle.handle.getDocumentScope();

                        // 0.15
                        // const function_scope = zlinter.zls.Analyser.innermostFunctionScopeAtIndex(doc_scope, tree.tokenStart(first_token - 1), .initOne(.function)).unwrap() orelse return null;

                        const function_scope = zlinter.zls.Analyser.innermostFunctionScopeAtIndex(
                            doc_scope,
                            tree.tokens.items(.start)[first_token - 1],
                        ).unwrap() orelse return null;

                        var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
                        const func = tree.fullFnProto(&fn_proto_buffer, doc_scope.getScopeAstNode(function_scope).?).?;

                        return .{
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
            const data = tree.nodes.items(.data)[node];
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
    const return_node = fn_proto.ast.return_type;
    const tag = zlinter.shims.nodeTag(tree, return_node);
    return switch (tag) {
        .error_union => true,
        else => tree.tokens.items(.tag)[tree.firstToken(return_node) - 1] == .bang,
    };
}

/// `errdefer` and `defer` calls
const DeferBlock = struct {
    children: []const std.zig.Ast.Node.Index,
};

fn deferBlock(doc: zlinter.session.LintDocument, node: std.zig.Ast.Node.Index) ?DeferBlock {
    const tree = doc.handle.tree;
    if (!isDeferBlock(tree, node)) return null;

    const data = zlinter.shims.nodeData(tree, node);
    const exp_node = switch (zlinter.version.zig) {
        .@"0.14" => data.rhs,
        .@"0.15" => data.opt_token_and_node[1],
    };

    if (isBlock(tree, exp_node)) {
        return .{ .children = doc.lineage.items(.children)[exp_node] orelse &.{} };
    } else {
        return .{ .children = &.{exp_node} };
    }
}

fn isDeferBlock(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    return switch (zlinter.shims.nodeTag(tree, node)) {
        .@"errdefer", .@"defer" => true,
        else => false,
    };
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
