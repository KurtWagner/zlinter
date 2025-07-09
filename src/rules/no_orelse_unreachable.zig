//! Enforces use of `.?` over `orelse unreachable` as `.?` offers comptime checks
//! as it does not control flow.

/// Config for no_orelse_unreachable rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_orelse_unreachable rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_orelse_unreachable),
        .run = &run,
    };
}

/// Runs the no_orelse_unreachable rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    var node: zlinter.shims.NodeIndexShim = .root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
        if (zlinter.shims.nodeTag(tree, node.toNodeIndex()) != .@"orelse") continue;

        const data = zlinter.shims.nodeData(tree, node.toNodeIndex());
        const rhs = switch (zlinter.version.zig) {
            .@"0.14" => data.rhs,
            .@"0.15" => data.node_and_node.@"1",
        };

        if (zlinter.shims.nodeTag(tree, rhs) != .unreachable_literal) continue;

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node.toNodeIndex()),
            .end = .endOfNode(tree, rhs),
            .message = try allocator.dupe(u8, "Prefer `.?` over `orelse unreachable`"),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
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
