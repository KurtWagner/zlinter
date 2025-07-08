//! Enforces no uses of `undefined`. There are some valid use case, in which
//! case uses should disable the line with an explanation.

/// Config for no_undefined rule.
pub const Config = struct {
    severity: zlinter.LintProblemSeverity = .warning,

    /// Skip if found in a function call:
    /// Case-insenstive
    exclude_in_fn: []const []const u8 = &.{"deinit"},

    /// Skip if found within `test { ... }` block
    exclude_tests: bool = true,

    /// Skips var declarations that name equals:
    /// Case-insensitive, for `var` (not `const`)
    exclude_var_decl_name_equals: []const []const u8 = &.{},

    /// Skips var declarations that name ends in:
    /// Case-insensitive, for `var` (not `const`)
    exclude_var_decl_name_ends_with: []const []const u8 = &.{
        "memory",
        "mem",
        "buffer",
        "buf",
        "buff",
    },
};

/// Builds and returns the no_undefined rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.no_undefined),
        .run = &run,
    };
}

/// Runs the no_undefined rule.
fn run(
    rule: zlinter.LintRule,
    _: zlinter.LintContext,
    doc: zlinter.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.LintOptions,
) error{OutOfMemory}!?zlinter.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: zlinter.shims.NodeIndexShim = .init(0);
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        if (zlinter.shims.nodeTag(tree, node.toNodeIndex()) != .identifier) continue :skip;
        if (!std.mem.eql(u8, tree.getNodeSource(node.toNodeIndex()), "undefined")) continue :skip;

        var decl_var_name: ?[]const u8 = null;
        if (doc.lineage.items(.parent)[node.index]) |parent| {
            if (tree.fullVarDecl(parent)) |var_decl| {
                if (tree.tokens.items(.tag)[var_decl.ast.mut_token] == .keyword_var) {
                    const name_token = var_decl.ast.mut_token + 1;
                    const name = tree.tokenSlice(name_token);
                    decl_var_name = name;

                    for (config.exclude_var_decl_name_equals) |var_name| {
                        if (std.ascii.eqlIgnoreCase(name, var_name)) continue :skip;
                    }
                    for (config.exclude_var_decl_name_ends_with) |var_name| {
                        if (std.ascii.endsWithIgnoreCase(name, var_name)) continue :skip;
                    }
                }
            }
        }

        var next_parent = connections.parent;
        while (next_parent) |parent| {
            // We expect any undefined with a test to simply be ignored as really we expect
            // the test to fail if there's issues
            if (config.exclude_tests and zlinter.shims.nodeTag(tree, parent) == .test_decl) continue :skip;

            // If assigned undefined in a deinit, ignore as it's a common pattern
            // assign undefined after freeing memory
            if (config.exclude_in_fn.len > 0) {
                if (tree.fullFnProto(&fn_proto_buffer, parent)) |fn_proto| {
                    if (fn_proto.name_token) |name_token| {
                        for (config.exclude_in_fn) |skip_fn_name| {
                            if (std.ascii.endsWithIgnoreCase(tree.tokenSlice(name_token), skip_fn_name)) continue :skip;
                        }
                    }
                }
            }

            // Look at lineage of containing block to see if "init" (or
            // configured method) is called on the var declaration set to
            // undefined. e.g., `this_was_undefined.init()`
            if (decl_var_name) |var_name| {
                if (switch (zlinter.shims.nodeTag(tree, parent)) {
                    .block_two,
                    .block_two_semicolon,
                    .block,
                    .block_semicolon,
                    => true,
                    else => false,
                }) {
                    var block_it = try doc.nodeLineageIterator(zlinter.shims.NodeIndexShim.init(parent), allocator);
                    defer block_it.deinit();

                    while (try block_it.next()) |block_tuple| {
                        const block_node, _ = block_tuple;
                        if (zlinter.shims.nodeTag(tree, block_node.toNodeIndex()) == .field_access) {
                            const node_data = zlinter.shims.nodeData(tree, block_node.toNodeIndex());
                            const lhs_node, const identifier_token = switch (zlinter.version.zig) {
                                .@"0.14" => .{ node_data.lhs, node_data.rhs },
                                .@"0.15" => .{ node_data.node_and_token.@"0", node_data.node_and_token.@"1" },
                            };
                            const lhs_source = tree.getNodeSource(lhs_node);
                            if (std.mem.eql(u8, lhs_source, var_name)) {
                                const identifier_name = tree.tokenSlice(identifier_token);
                                if (std.mem.eql(u8, identifier_name, "init")) {
                                    continue :skip;
                                }
                            }
                        }
                    }
                }
            }

            next_parent = doc.lineage.items(.parent)[zlinter.shims.NodeIndexShim.init(parent).index];
        }

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node.toNodeIndex()),
            .end = .endOfNode(tree, node.toNodeIndex()),
            .message = try allocator.dupe(u8, "Take care when using `undefined`"),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
