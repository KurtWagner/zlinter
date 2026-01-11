//! Example rule for those that don't like cats

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    message: ?[]const u8 = null,
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = "no_cats",
        .run = &run,
    };
}

fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;
    var token: Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (tree.tokens.items(.tag)[token] == .identifier) {
            const name = tree.tokenSlice(token);
            if (std.ascii.indexOfIgnoreCase(name, "cats") != null) {
                try lint_problems.append(gpa, .{
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                    .start = .startOfToken(tree, token),
                    .end = .endOfToken(tree, token),
                    .message = try gpa.dupe(u8, config.message orelse "I'm scared of cats"),
                });
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

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
