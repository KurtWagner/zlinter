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
        .execution = .syntax_only,
        .run = &run,
    };
}

/// Runs the switch_case_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    const session_arena = session.runtime.sessionArena();
    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const switch_info = tree.fullSwitch(node) orelse continue;

        for (switch_info.ast.cases, 0..) |case_node, i| {
            const switch_case = tree.fullSwitchCase(case_node).?;

            // If values is empty, this is an else case
            if (switch_case.ast.values.len == 0) {
                if (config.else_is_last != .off and i != switch_info.ast.cases.len - 1) {
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.else_is_last,
                        .start = .startOfNode(tree, case_node),
                        .end = .endOfNode(tree, case_node),
                        .message = try session_arena.dupe(u8, "`else` should be last in switch statements"),
                    });
                }
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            lint_problems.items,
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
