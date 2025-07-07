//! Enforces no uses of `undefined`. There are some valid use case, in which
//! case uses should disable the line with an explanation.

/// Config for no_undefined rule.
pub const Config = struct {
    severity: zlinter.LintProblemSeverity = .warning,

    /// Case-insenstive
    skip_when_used_in_fn: []const []const u8 = &.{"deinit"},
    skip_when_used_in_test: bool = true,
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

        var next_parent = connections.parent;
        while (next_parent) |parent| {
            // We expect any undefined with a test to simply be ignored as really we expect
            // the test to fail if there's issues
            if (config.skip_when_used_in_test and zlinter.shims.nodeTag(tree, parent) == .test_decl) continue :skip;

            // If assigned undefined in a deinit, ignore as it's a common pattern
            // assign undefined after freeing memory
            if (config.skip_when_used_in_fn.len > 0) {
                if (tree.fullFnProto(&fn_proto_buffer, parent)) |fn_proto| {
                    if (fn_proto.name_token) |name_token| {
                        for (config.skip_when_used_in_fn) |skip_fn_name| {
                            if (std.ascii.endsWithIgnoreCase(tree.tokenSlice(name_token), skip_fn_name)) continue :skip;
                        }
                    }
                }
            }
            next_parent = doc.lineage.items(.parent)[parent];
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
