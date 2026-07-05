//! Disallows todo comments
//!
//! `TODO` comments are often used to indicate missing logic, features or the existence
//! of bugs. While this is useful during development, leaving them untracked can
//! lead to them being forgotten or not prioritised correctly.
//!
//! If you must leave a todo comment it's best to include a link to an issue
//! in your issue tracker so it's visible, prioritized and won't be forgotten.
//!
//! By default, `no_todo` allows TODO comments when they include either a
//! `#123`-style issue reference or an `http(s)` URL. Both checks are
//! configurable.

/// Config for no_todo rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Exclude todo comments that contain a `#[0-9]+` anywhere in the todo content.
    /// For example, `// TODO(#10): <info>` or `// TODO: Fix #10`.
    exclude_if_contains_issue_number: bool = true,

    /// Exclude todo comments that contain a URL in a word token or nested in
    /// the todo suffix. For example, `// TODO(http://my-issue-tracker.com/10): <info>`
    /// or `// TODO: Fix http://my-issue-tracker.com/10`.
    exclude_if_contains_url: bool = true,
};

/// Builds and returns the no_todo rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_todo),
        .run = &run,
    };
}

/// Runs the no_todo rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    const tree = doc.tree(session);
    const source = tree.source;

    comments: for (doc.comments.comments) |comment| {
        if (comment.kind != .todo) continue :comments;

        const todo = comment.kind.todo;

        if (todo.inner_content) |inner_content| {
            if (containsAllowedTrackingReference(
                doc.comments.getRangeContent(inner_content, source),
                config,
            ))
                continue :comments;
        }

        if (todo.content) |content| {
            if (containsAllowedTrackingReference(
                doc.comments.getRangeContent(content, source),
                config,
            ))
                continue :comments;
        }

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfComment(doc.comments, comment),
            .end = .endOfComment(doc.comments, comment),
            .message = try session_arena.dupe(u8, if (config.exclude_if_contains_issue_number or config.exclude_if_contains_url)
                "Avoid todo comments that don't link to a tracked issue"
            else
                "Avoid todo comments"),
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

// It would be nice to walk the comment tokens directly, but `:` is a special
// character in TODO syntax and URLs (e.g. `http://`) are easier to keep as
// whitespace-delimited word tokens. This heuristic is intentionally narrow and
// only needs to be good enough for TODO comments.
fn containsAllowedTrackingReference(content: []const u8, config: Config) bool {
    var it = std.mem.splitAny(
        u8,
        content,
        &std.ascii.whitespace,
    );
    while (it.next()) |word| {
        if (config.exclude_if_contains_issue_number and looksLikeIssueId(word)) return true;
        if (config.exclude_if_contains_url and looksLikeUrl(word)) return true;
    }
    return false;
}

fn looksLikeIssueId(content: []const u8) bool {
    var i: usize = 0;
    while (i + 1 < content.len) : (i += 1) {
        if (content[i] != '#') continue;
        if (!std.ascii.isDigit(content[i + 1])) continue;

        var j = i + 2;
        while (j < content.len and std.ascii.isDigit(content[j])) : (j += 1) {}
        return true;
    }

    return false;
}

test looksLikeIssueId {
    inline for (&.{ "#0", "#1234", "foo #1234 bar", "(#42)", "TODO(#123): fix", std.fmt.comptimePrint("#{d}", .{std.math.maxInt(usize)}) }) |valid| {
        std.testing.expect(looksLikeIssueId(valid)) catch |e| {
            std.debug.print("Expected '{s}' to look like an issue id\n", .{valid});
            return e;
        };
    }

    inline for (&.{ "", "#", "#-1", "0", "1234", "not #abc", "TODO(#abc)", std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}) }) |valid| {
        std.testing.expect(!looksLikeIssueId(valid)) catch |e| {
            std.debug.print("Expected '{s}' to NOT look like an issue id\n", .{valid});
            return e;
        };
    }
}

// Just needs to be good enough... not perfect.
fn looksLikeUrl(content: []const u8) bool {
    // Keep URL matching deliberately lightweight. The current policy is the
    // minimal host-shaped heuristic already covered by the tests: we accept
    // short forms such as `http://a.c` and reject bare or incomplete schemes
    // such as `http://`, `https://a`, and `http://a.`.
    inline for (&.{ "http://", "https://" }) |prefix| {
        var search_start: usize = 0;
        while (std.mem.findPos(u8, content, search_start, prefix)) |index| {
            const prefix_is_word_start = index == 0 or std.mem.findScalar(u8, "([{", content[index - 1]) != null;
            if (prefix_is_word_start and content.len >= index + prefix.len + 3) return true;
            search_start = index + 1;
        }
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

    inline for (&.{ "", "http", "https", "http://", "https://a", "http://a.", "abc_https://abc", "not-url-http://a.cc" }) |valid| {
        std.testing.expect(!looksLikeUrl(valid)) catch |e| {
            std.debug.print("Expected '{s}' to NOT look like a url id\n", .{valid});
            return e;
        };
    }
}

test containsAllowedTrackingReference {
    const issue_enabled = Config{
        .exclude_if_contains_issue_number = true,
        .exclude_if_contains_url = false,
        .severity = .warning,
    };
    const url_enabled = Config{
        .exclude_if_contains_issue_number = false,
        .exclude_if_contains_url = true,
        .severity = .warning,
    };
    const both_enabled = Config{
        .exclude_if_contains_issue_number = true,
        .exclude_if_contains_url = true,
        .severity = .warning,
    };
    const both_disabled = Config{
        .exclude_if_contains_issue_number = false,
        .exclude_if_contains_url = false,
        .severity = .warning,
    };

    inline for (&.{
        .{ .content = "fix #10", .config = issue_enabled, .expected = true },
        .{ .content = "fix #10", .config = url_enabled, .expected = false },
        .{ .content = "see https://example.com/10", .config = url_enabled, .expected = true },
        .{ .content = "see https://example.com/10", .config = issue_enabled, .expected = false },
        .{ .content = "fix #10", .config = both_enabled, .expected = true },
        .{ .content = "fix https://example.com/10", .config = both_disabled, .expected = false },
    }) |case| {
        try std.testing.expectEqual(
            case.expected,
            containsAllowedTrackingReference(case.content, case.config),
        );
    }
}

test "TODO comment default config excludes issue and URL references" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO(#10): fix
        \\// TODO: see https://example.com/10
        \\// TODO: still report me
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: still report me\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test "TODO comment reports when both exclusions are disabled" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO(#10): fix this later
        \\// TODO: see https://example.com/10
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = false,
            .exclude_if_contains_url = false,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO(#10): fix this later\n",
                .message = "Avoid todo comments",
            },
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: see https://example.com/10\n",
                .message = "Avoid todo comments",
            },
        },
    );
}

test "TODO comment after string is still reported" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const a = "hello"; // TODO: still report me
        \\const b = 'x'; // todo: still report me too
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: still report me\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// todo: still report me too\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test "TODO comment without URL" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: This is a bare todo with no URL
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = false,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: This is a bare todo with no URL\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test "TODO comment without issue id" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: This is a bare todo with no issue id
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = false,
            .severity = .@"error",
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .@"error",
                .slice = "// TODO: This is a bare todo with no issue id\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test "TODO comment with issue id" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO(#10): This is a todo tied to an issue
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = false,
            .severity = .warning,
        },
        &.{},
    );
}

test "TODO comment with url" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: https://example.com/issues/10
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = false,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{},
    );
}

test "TODO comment with neither issue id nor url" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: This is a bare todo with no issue id or url
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: This is a bare todo with no issue id or url\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test "TODO comment severity off" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: This is a bare todo that would normally be flagged
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = false,
            .exclude_if_contains_url = false,
            .severity = .off,
        },
        &.{},
    );
}

test "TODO comment with issue id and url" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO(#10): https://example.com/issues/10
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{},
    );
}

test "TODO comment with issue id in punctuation" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: Fix #123.
        \\// TODO: see (#123)
        \\// TODO(#123): fix
        \\// TODO: not #abc
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = true,
            .exclude_if_contains_url = false,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: not #abc\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test "TODO comment with url in punctuation" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ 
        \\// TODO: see (https://example.com/1)
        \\// TODO: see [http://example.com/1]
        \\// TODO: http://
        \\
    ,
        .{},
        Config{
            .exclude_if_contains_issue_number = false,
            .exclude_if_contains_url = true,
            .severity = .warning,
        },
        &.{
            .{
                .rule_id = "no_todo",
                .severity = .warning,
                .slice = "// TODO: http://\n",
                .message = "Avoid todo comments that don't link to a tracked issue",
            },
        },
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
