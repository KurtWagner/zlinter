//! Enforces use of optional unwrap shorthand `.?` instead of `orelse unreachable`.
//!
//! `.?` is the dedicated syntax for asserting that an optional is non-null.
//!
//! While the language reference describes `.?` as equivalent to
//! `a orelse unreachable`, it currently treats `.?` more eagerly in some
//! comptime-known cases, turning a null unwrap into a compile error instead of
//! preserving `unreachable` as a runtime safety failure.
//!
//! Use `orelse` for real fallback values or intentional fallback control flow.

/// Config for no_orelse_unreachable rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_orelse_unreachable rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_orelse_unreachable),
        .run = &run,
    };
}

/// Runs the no_orelse_unreachable rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .@"orelse") continue;

        const data = tree.nodeData(node);
        const rhs = data.node_and_node.@"1";

        if (!isUnreachableExpr(tree, rhs)) continue;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, rhs),
            .message = try session_arena.dupe(u8, "Prefer `.?` over `orelse unreachable`"),
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

fn isUnreachableExpr(tree: Ast, node: Ast.Node.Index) bool {
    const unwrapped = unwrapGroupedExpression(tree, node);
    return tree.nodeTag(unwrapped) == .unreachable_literal or
        isUnreachableBlock(tree, unwrapped);
}

fn unwrapGroupedExpression(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (tree.nodeTag(current) == .grouped_expression)
        current = tree.nodeData(current).node_and_token[0];
    return current;
}

fn isUnreachableBlock(tree: Ast, node: Ast.Node.Index) bool {
    const tag = tree.nodeTag(node);
    if (tag != .block_two and tag != .block_two_semicolon) return false;

    const data = tree.nodeData(node);
    const lhs = data.opt_node_and_opt_node.@"0".unwrap();
    const rhs = data.opt_node_and_opt_node.@"1".unwrap();

    if (lhs) |lhs_node| {
        return rhs == null and tree.nodeTag(lhs_node) == .unreachable_literal;
    }
    return false;
}

test {
    std.testing.refAllDecls(@This());
}

test "no_orelse_unreachable invalid syntax should not crash" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\const a = b orelse;
        \\const c = d orelse (;
        \\const e = f orelse {;
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{ .allow_parse_errors = true },
        Config{ .severity = .@"error" },
        &.{},
    );
}

test "no_orelse_unreachable" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\const a = b orelse unreachable;
        \\const d = e orelse { unreachable; };
        \\const g = h orelse (unreachable);
        \\const i = j orelse ({ unreachable; });
        \\const c = d.?;
        \\const e = f orelse 1;
        \\const k = l orelse (1);
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .severity = severity,
            },
            &.{
                .{
                    .rule_id = "no_orelse_unreachable",
                    .severity = severity,
                    .slice = "b orelse unreachable",
                    .message = "Prefer `.?` over `orelse unreachable`",
                },
                .{
                    .rule_id = "no_orelse_unreachable",
                    .severity = severity,
                    .slice = "e orelse { unreachable; }",
                    .message = "Prefer `.?` over `orelse unreachable`",
                },
                .{
                    .rule_id = "no_orelse_unreachable",
                    .severity = severity,
                    .slice = "h orelse (unreachable)",
                    .message = "Prefer `.?` over `orelse unreachable`",
                },
                .{
                    .rule_id = "no_orelse_unreachable",
                    .severity = severity,
                    .slice = "j orelse ({ unreachable; })",
                    .message = "Prefer `.?` over `orelse unreachable`",
                },
            },
        );

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .severity = .off,
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
