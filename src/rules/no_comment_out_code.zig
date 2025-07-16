//! Enforces that there's no source code comments that look like code.
//!
//! Code encased in backticks, like `this` is ignored.

/// Config for no_comment_out_code rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_comment_out_code rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_comment_out_code),
        .run = &run,
    };
}

/// Runs the no_comment_out_code rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    var content_accumulator = std.ArrayList(u8).init(allocator);
    defer content_accumulator.deinit();

    var first_comment: ?zlinter.comments.Comment = null;
    var last_comment: ?zlinter.comments.Comment = null;

    var prev_line: u32 = 0;

    for (doc.comments.comments) |comment| {
        if (comment.kind != .line) continue;
        const contents = doc.comments.getCommentContent(comment, doc.handle.tree.source);
        const line = doc.comments.tokens[comment.first_token].line;
        defer prev_line = line;

        if (content_accumulator.items.len == 0 or prev_line == line - 1) {
            try content_accumulator.appendSlice(contents);
            try content_accumulator.append('\n');
        } else {
            if (content_accumulator.items.len > 0) {
                const content_block = try content_accumulator.toOwnedSliceSentinel(0);
                defer allocator.free(content_block);

                if (try looksLikeCode(content_block, allocator)) {
                    try lint_problems.append(.{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfComment(doc.comments, first_comment.?),
                        .end = .endOfComment(doc.comments, last_comment.?),
                        .message = try allocator.dupe(u8, "Avoid code in comments"),
                    });
                }

                first_comment = null;
                last_comment = null;
            }
            try content_accumulator.appendSlice(contents);
            try content_accumulator.append('\n');
        }

        first_comment = first_comment orelse comment;
        last_comment = comment;
    }

    if (content_accumulator.items.len > 0) {
        const content_block = try content_accumulator.toOwnedSliceSentinel(0);
        defer allocator.free(content_block);

        if (try looksLikeCode(content_block, allocator)) {
            try lint_problems.append(.{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfComment(doc.comments, first_comment.?),
                .end = .endOfComment(doc.comments, last_comment.?),
                .message = try allocator.dupe(u8, "Avoid code in comments"),
            });
        }

        first_comment = null;
        last_comment = null;
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(),
        )
    else
        null;
}

fn looksLikeCode(content: [:0]const u8, gpa: std.mem.Allocator) !bool {
    if (content.len == 0) return false;

    var ast = try std.zig.Ast.parse(gpa, content, .zig);
    defer ast.deinit(gpa);

    // This heuristic will need to evolve, it's currently:
    // 1. More than just a root node
    // 2. Has at least 5 times more nodes than errors

    std.debug.print("Nodes: {d}, Tokens: {d}, Errors: {d}\n", .{ ast.nodes.len, ast.tokens.len, ast.errors.len });
    return (ast.nodes.len > 1 and ast.nodes.len > (ast.errors.len * 5));
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
