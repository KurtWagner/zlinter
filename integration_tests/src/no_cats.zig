//! Example rule for those that don't like cats

const std = @import("std");
const zlinter = @import("zlinter");

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    message: ?[]const u8 = null,
};

pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = "no_cats",
        .run = &run,
    };
}

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
    var token: std.zig.Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (tree.tokens.items(.tag)[token] == .identifier) {
            const name = tree.tokenSlice(token);
            if (std.ascii.indexOfIgnoreCase(name, "cats") != null) {
                try lint_problems.append(allocator, .{
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                    .start = .startOfToken(tree, token),
                    .end = .endOfToken(tree, token),
                    .message = try allocator.dupe(u8, config.message orelse "I'm scared of cats"),
                });
            }
        }
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
