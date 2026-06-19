//! Require the source code to be formatted with zig fmt

/// Config for require_fmt rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the require_fmt rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return .{
        .rule_id = @tagName(.require_fmt),
        .run = &run,
        .execution = .syntax_only,
    };
}

/// Runs the require_fmt rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.tree(session);
    const fmt = try tree.renderAlloc(gpa);
    defer gpa.free(fmt);

    if (!std.mem.eql(u8, fmt, tree.source)) {
        try lint_problems.append(gpa, .{
            .start = .zero,
            .end = .zero,
            .message = try gpa.dupe(u8, "File is not formatted"),
            .rule_id = rule.rule_id,
            .severity = config.severity,
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.absPath(session),
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

test "require_fmt" {
    const rule = buildRule(.{});
    const formatted_source =
        \\//! Some root source file
        \\const foo: u32 = 67;
        \\
    ;

    const unformatted_source =
        \\//! Some root source file
        \\const foo: u32 = 67;
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            formatted_source,
            .{},
            Config{ .severity = severity },
            &.{},
        );
        try zlinter.testing.testRunRule(
            rule,
            unformatted_source,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = "require_fmt",
                    .severity = severity,
                    .slice = "",
                    .message = "File is not formatted",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        unformatted_source,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
