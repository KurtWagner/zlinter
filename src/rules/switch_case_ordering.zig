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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.else_is_last == .off) return null;

    const session_arena = session.runtime.sessionArena();
    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const switch_info = tree.fullSwitch(node) orelse continue;

        for (switch_info.ast.cases, 0..) |case_node, i|
            if (zlinter.ast.isSwitchElseProng(tree, case_node))
                if (i != switch_info.ast.cases.len - 1)
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.else_is_last,
                        .start = .startOfNode(tree, case_node),
                        .end = .endOfNode(tree, case_node),
                        .message = try session_arena.dupe(u8, "`else` should be last in switch statements"),
                    });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

test "switch_case_ordering else is last" {
    const rule = buildRule(.{});
    const source =
        \\fn value(input: u8) u8 {
        \\    return switch (input) {
        \\        else => 0,
        \\        1 => 1,
        \\    };
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .else_is_last = severity },
            &.{
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "else => 0",
                    .message = "`else` should be last in switch statements",
                },
            },
        );

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .else_is_last = .off },
        &.{},
    );
}

test "switch_case_ordering allows else last and absent" {
    const rule = buildRule(.{});
    const source =
        \\fn values(input: u8) u8 {
        \\    const first = switch (input) {
        \\        1 => 1,
        \\        1, 2 => 2,
        \\        1...5 => 5,
        \\        else => 0,
        \\    };
        \\    const second = switch (input) {
        \\        1 => 1,
        \\        1, 2 => 2,
        \\        1...5 => 5,
        \\    };
        \\    return first + second;
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{},
    );
}

test "switch_case_ordering tolerates parser recovery input" {
    const rule = buildRule(.{});
    const source =
        \\fn value(input: u8) u8 {
        \\    return switch (input) {
        \\        else => ,
        \\        1 => 1,
        \\    };
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{ .allow_parse_errors = true },
        Config{},
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
