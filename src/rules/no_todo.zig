//! Disallows todo comments
//!
//! `TODO` comments are often used to indicate missing logic, features or the existence
//! of bugs. While this is useful during development, leaving them untracked can
//! lead to them being forgotten or not prioritised correctly.
//!
//! If you must leave a todo comment it's best to include a link to an issue
//! in your issue tracker so it's visible, prioritized and won't be forgotten.

/// Config for no_todo rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Exclude todo comments that contain a `#[0-9]+` in a word token or nested in
    /// the todo suffix. For example, `// TODO(#10): <info>` or `// TODO: Fix #10`
    exclude_if_contains_issue_number: bool = true,

    /// Exclude todo comments that contain a url in a word token or nested in
    /// the todo suffix. For example, `// TODO(http://my-issue-tracker.com/10): <info>`
    /// or `// TODO: Fix http://my-issue-tracker.com/10`
    exclude_if_contains_url: bool = true,
};

/// Builds and returns the no_todo rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_todo),
        .run = &run,
    };
}

/// Runs the no_todo rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    var content_accumulator = std.ArrayList(u8).init(allocator);
    defer content_accumulator.deinit();

    const tree = doc.handle.tree;
    const source = tree.source;

    nodes: for (doc.comments.comments) |comment| {
        if (comment.kind != .todo) continue :nodes;

        const todo = comment.kind.todo;

        if (config.exclude_if_contains_issue_number or
            config.exclude_if_contains_url)
        {
            if (todo.inner_content) |inner_content| {
                if (isExcluded(
                    doc.comments.getRangeContent(inner_content, source),
                    config,
                ))
                    continue :nodes;
            }

            if (todo.content) |content| {
                if (isExcluded(
                    doc.comments.getRangeContent(content, source),
                    config,
                ))
                    continue :nodes;
            }
        }

        try lint_problems.append(.{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfComment(doc.comments, comment),
            .end = .endOfComment(doc.comments, comment),
            .message = try allocator.dupe(u8, if (config.exclude_if_contains_issue_number or !config.exclude_if_contains_url)
                "Avoid todo comments that don't link to a tracked issue"
            else
                "Avoid todo comments"),
        });
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

// It would be nice to walk to the comment tokens but we use ":" as a special
// character, which makes urls (e.g, http://) more difficult so to keep it
// super simple we'll iterate again using whitespace delimiter. This will
// probably be ok as we're just doing this for TODO comments not all comments.
fn isExcluded(content: []const u8, config: Config) bool {
    var it = std.mem.splitAny(
        u8,
        content,
        &std.ascii.whitespace,
    );
    while (it.next()) |word| {
        if (config.exclude_if_contains_issue_number and looksLikeIssueId(word)) {
            return true;
        }
        if (config.exclude_if_contains_issue_number and looksLikeUrl(word)) {
            return true;
        }
    }
    return false;
}

fn looksLikeIssueId(content: []const u8) bool {
    if (content.len < 2) return false;
    if (content[0] != '#') return false;

    _ = std.fmt.parseInt(usize, content[1..], 10) catch return false;
    return true;
}

test looksLikeIssueId {
    inline for (&.{ "#0", "#1234", std.fmt.comptimePrint("#{d}", .{std.math.maxInt(usize)}) }) |valid| {
        std.testing.expect(looksLikeIssueId(valid)) catch |e| {
            std.debug.print("Expected '{s}' to look like an issue id\n", .{valid});
            return e;
        };
    }

    inline for (&.{ "", "#", "#-1", "0", "1234", std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}) }) |valid| {
        std.testing.expect(!looksLikeIssueId(valid)) catch |e| {
            std.debug.print("Expected '{s}' to NOT look like an issue id\n", .{valid});
            return e;
        };
    }
}

// Just needs to be good enough... not perfect.
fn looksLikeUrl(content: []const u8) bool {
    inline for (&.{ "http://", "https://" }) |prefix| {
        if (content.len >= prefix.len + 3 and
            std.ascii.startsWithIgnoreCase(content, prefix))
            return true;
    }
    return false;
}

test looksLikeUrl {
    inline for (&.{ "http://a.c", "https://github.com/user/repo/issue/12" }) |valid| {
        std.testing.expect(looksLikeUrl(valid)) catch |e| {
            std.debug.print("Expected '{s}' to look like a url id\n", .{valid});
            return e;
        };
    }

    inline for (&.{ "", "http", "https", "http://", "https://a", "http://a." }) |valid| {
        std.testing.expect(!looksLikeUrl(valid)) catch |e| {
            std.debug.print("Expected '{s}' to NOT look like a url id\n", .{valid});
            return e;
        };
    }
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
