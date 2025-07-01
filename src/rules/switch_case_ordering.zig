//! Enforces an order of values in switch statements

/// Config for switch_case_ordering rule.
pub const Config = struct {
    else_is_last: zlinter.LintProblemSeverity = .warning,
};

/// Builds and returns the switch_case_ordering rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.switch_case_ordering),
        .run = &run,
    };
}

/// Runs the switch_case_ordering rule.
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
        const switch_info = tree.fullSwitch(node.toNodeIndex()) orelse continue;

        for (switch_info.ast.cases, 0..) |case_node, i| {
            const switch_case = tree.fullSwitchCase(case_node).?;

            // If values is empty, this is an else case
            if (switch_case.ast.values.len == 0) {
                if (config.else_is_last != .off and i != switch_info.ast.cases.len - 1) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.else_is_last,
                        .start = .startOfNode(tree, case_node),
                        .end = .endOfNode(tree, case_node),
                        .message = try allocator.dupe(u8, "`else` should be last in switch statements"),
                    });
                }
            }
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
