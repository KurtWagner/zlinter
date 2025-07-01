//! Enforces no uses of `undefined`. There are some valid use case, in which
//! case uses should disable the line with an explanation.

/// Config for no_undefined rule.
pub const Config = struct {
    severity: zlinter.LintProblemSeverity = .warning,
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

    var node: zlinter.shims.NodeIndexShim = .init(0);
    while (node.index < tree.nodes.len) : (node.index += 1) {
        if (zlinter.shims.nodeTag(tree, node.toNodeIndex()) != .identifier) continue;

        if (std.mem.eql(u8, tree.getNodeSource(node.toNodeIndex()), "undefined")) {
            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfNode(tree, node.toNodeIndex()),
                .end = .endOfNode(tree, node.toNodeIndex()),
                .message = try allocator.dupe(u8, "Take care when using `undefined`"),
            });
        }
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
