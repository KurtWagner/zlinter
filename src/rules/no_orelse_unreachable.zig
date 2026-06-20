//! Enforces use of `.?` over `orelse unreachable` as `.?` offers comptime checks
//! as it does not control flow.

// TODO: Should this catch `const g = h orelse { unreachable; };`

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
        .execution = .syntax_only,
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

        const rhs_tag = tree.nodeTag(rhs);
        if (rhs_tag != .unreachable_literal and !isUnreachableBlock(tree, rhs)) continue;

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
            session_arena,
            doc.absPath(session),
            lint_problems.items,
        )
    else
        null;
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

test "no_orelse_unreachable" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\const a = b orelse unreachable;
        \\const d = e orelse { unreachable; };
        \\const c = d.?;
        \\const e = f orelse 1;
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
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
            },
        );
    }

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
