//! Example rule for those that don't like cats

pub const Config = struct {
    severity: zlinter.rules.LintProblemSeverity = .warning,
    message: ?[]const u8 = null,
};

pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = "no_cats",
        .execution = .syntax_only,
        .run = &run,
    };
}

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
    defer lint_problems.deinit(session_arena);

    const tree = doc.tree(session);
    var token: Ast.TokenIndex = 0;
    while (token < tree.tokens.len) : (token += 1) {
        if (tree.tokens.items(.tag)[token] == .identifier) {
            const name = tree.tokenSlice(token);
            if (std.ascii.findIgnoreCase(name, "cats") != null) {
                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                    .start = .startOfToken(tree, token),
                    .end = .endOfToken(tree, token),
                    .message = try session_arena.dupe(u8, config.message orelse "I'm scared of cats"),
                });
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            try lint_problems.toOwnedSlice(session_arena),
        )
    else
        null;
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
