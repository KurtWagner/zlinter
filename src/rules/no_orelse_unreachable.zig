//! Enforces use of `.?` over `orelse unreachable` as `.?` offers comptime checks
//! as it does not control flow.

// TODO: Should this catch `const g = h orelse { unreachable; };`

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

test "no_orelse_unreachable" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\const a = b orelse unreachable;
        \\const c = d.?;
        \\const e = f orelse 1;
    ;
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
        source,
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
    );

    inline for (&.{"b orelse unreachable"}, 0..) |slice, i| {
        try std.testing.expectEqualStrings(slice, result.problems[i].sliceSource(source));
    }

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_orelse_unreachable",
                .severity = .warning,
                .start = .{
                    .byte_offset = 10,
                    .line = 0,
                    .column = 10,
                },
                .end = .{
                    .byte_offset = 30,
                    .line = 0,
                    .column = 30,
                },
                .message = "Prefer `.?` over `orelse unreachable`",
                .disabled_by_comment = false,
                .fix = null,
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
