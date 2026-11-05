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
    var lint_problems = shims.ArrayList(zlinter.results.LintProblem){};
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    var node: NodeIndexShim = NodeIndexShim.root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
            const node_idx = node.toNodeIndex();
            if (tree.nodes.items(.tag)[node_idx] != .@"switch" and tree.nodes.items(.tag)[node_idx] != .switch_comma) continue;
            const data = tree.nodes.items(.data)[node_idx];
            const cases_range = tree.extraData(data.rhs, Ast.Node.SubRange);
            const case_count = cases_range.end - cases_range.start;
            for (cases_range.start..cases_range.end, 0..) |extra_idx, i| {
                const case_node = tree.extra_data[extra_idx];
                const switch_case = tree.fullSwitchCase(case_node) orelse continue;
                if (switch_case.ast.values.len == 0) {
                    if (config.else_is_last != .off and i != case_count - 1) {
                        try lint_problems.append(gpa, .{
                            .rule_id = rule.rule_id,
                            .severity = config.else_is_last,
                            .start = zlinter.results.LintProblemLocation.startOfNode(tree, case_node),
                            .end = zlinter.results.LintProblemLocation.endOfNode(tree, case_node),
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

test "else not last" {
    const rule = buildRule(.{});
    const source =
        \\const a: enum { x, y } = .x;
        \\const s = switch (a) {
        \\    .x => {},
        \\    else => {},
        \\    .y => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "switch_case_ordering",
                .severity = .warning,
                .slice = "else => {}",
                .message = "`else` should be last in switch statements",
            },
        },
    );
}

test "else last" {
    const rule = buildRule(.{});
    const source =
        \\const a: enum { x, y } = .x;
        \\const s = switch (a) {
        \\    .x => {},
        \\    .y => {},
        \\    else => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{},
    );
}

test "else only" {
    const rule = buildRule(.{});
    const source =
        \\const a: u32 = 1;
        \\const s = switch (a) {
        \\    else => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{},
    );
}

test "no else" {
    const rule = buildRule(.{});
    const source =
        \\const a: u32 = 1;
        \\const s = switch (a) {
        \\    1 => {},
        \\    2 => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{},
    );
}

const std = @import("std");
pub const Ast = std.zig.Ast;
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;

test "else_is_last off" {
    const rule = buildRule(.{});
    const source =
        \\const a: enum { x, y } = .x;
        \\const s = switch (a) {
        \\    .x => {},
        \\    else => {},
        \\    .y => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .else_is_last = .off },
        &.{},
    );
}

test "else_is_last error" {
    const rule = buildRule(.{});
    const source =
        \\const a: enum { x, y } = .x;
        \\const s = switch (a) {
        \\    .x => {},
        \\    else => {},
        \\    .y => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .else_is_last = .@"error" },
        &.{
            .{
                .rule_id = "switch_case_ordering",
                .severity = .@"error",
                .slice = "else => {}",
                .message = "`else` should be last in switch statements",
            },
        },
    );
}

test "switch_comma" {
    const rule = buildRule(.{});
    const source =
        \\const a: enum { x, y } = .x;
        \\const s = switch (a) {
        \\    .x => {},
        \\    else => {},
        \\    .y => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "switch_case_ordering",
                .severity = .warning,
                .slice = "else => {}",
                .message = "`else` should be last in switch statements",
            },
        },
    );
}

test "multiple switches" {
    const rule = buildRule(.{});
    const source =
        \\const a: enum { x, y } = .x;
        \\const s1 = switch (a) {
        \\    else => {},
        \\    .x => {},
        \\};
        \\const s2 = switch (a) {
        \\    .x => {},
        \\    else => {},
        \\    .y => {},
        \\};
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "switch_case_ordering",
                .severity = .warning,
                .slice = "else => {}",
                .message = "`else` should be last in switch statements",
            },
            .{
                .rule_id = "switch_case_ordering",
                .severity = .warning,
                .slice = "else => {}",
                .message = "`else` should be last in switch statements",
            },
        },
    );
}