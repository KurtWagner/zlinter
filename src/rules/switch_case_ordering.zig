//! Enforces an order of values in `switch` statements.

/// Config for switch_case_ordering rule.
pub const Config = struct {
    /// The severity for when `else` is not last in a `switch` (off, warning, error).
    else_is_last: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the switch_case_ordering rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.switch_case_ordering),
        .run = &run,
    };
}

/// Runs the switch_case_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    var node: NodeIndexShim = .root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
        const switch_info = tree.fullSwitch(node.toNodeIndex()) orelse continue;

        for (switch_info.ast.cases, 0..) |case_node, i| {
            const switch_case = tree.fullSwitchCase(case_node).?;

            // If values is empty, this is an else case
            if (switch_case.ast.values.len == 0) {
                if (config.else_is_last != .off and i != switch_info.ast.cases.len - 1) {
                    try lint_problems.append(gpa, .{
                        .rule_id = rule.rule_id,
                        .severity = config.else_is_last,
                        .start = .startOfNode(tree, case_node),
                        .end = .endOfNode(tree, case_node),
                        .message = try gpa.dupe(u8, "`else` should be last in switch statements"),
                    });
                }
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
