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
        .run = &run,
    };
}

/// Runs the no_orelse_unreachable rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    var node: NodeIndexShim = .root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
        if (shims.nodeTag(tree, node.toNodeIndex()) != .@"orelse") continue;

        const data = shims.nodeData(tree, node.toNodeIndex());
        const rhs = switch (zlinter.version.zig) {
            .@"0.14" => data.rhs,
            .@"0.15", .@"0.16" => data.node_and_node.@"1",
        };

        if (shims.nodeTag(tree, rhs) != .unreachable_literal) continue;

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

test "no_orelse_unreachable" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\const a = b orelse unreachable;
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
                    .slice = "b orelse unreachable;",
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
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
