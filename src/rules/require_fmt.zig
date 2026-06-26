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
    };
}

/// Runs the require_fmt rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const tree = doc.tree(session);
    // Invalid ASTs will trip assertions inside Zig's renderer.
    if (tree.errors.len > 0) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const fmt = try tree.renderAlloc(rule_arena);
    const normalized_source = try normalizeNewLinesAlloc(tree.source, rule_arena);

    if (!std.mem.eql(u8, fmt, normalized_source)) {
        const diff = firstDifference(fmt, normalized_source);
        const source_offset = normalizedOffsetToSourceOffset(
            tree.source,
            diff,
        );

        try lint_problems.append(session_arena, .{
            .start = .{ .byte_offset = source_offset },
            .end = .{ .byte_offset = source_offset },
            .message = try session_arena.dupe(u8, "File is not formatted"),
            .rule_id = rule.rule_id,
            .severity = config.severity,
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

fn firstDifference(a: []const u8, b: []const u8) usize {
    const common_len = @min(a.len, b.len);
    for (a[0..common_len], b[0..common_len], 0..) |ca, cb, i|
        if (ca != cb) return i;
    return common_len;
}

fn normalizeNewLinesAlloc(input: []const u8, rule_arena: std.mem.Allocator) ![]const u8 {
    var result: std.ArrayList(u8) = try .initCapacity(rule_arena, input.len);
    for (input) |c|
        if (c != '\r') result.appendAssumeCapacity(c);
    return result.toOwnedSlice(rule_arena);
}

fn normalizedOffsetToSourceOffset(source: []const u8, normalized_offset: usize) usize {
    if (source.len == 0) return 0;

    var source_offset: usize = 0;
    var normalized_index: usize = 0;

    while (source_offset < source.len) : (source_offset += 1) {
        if (source[source_offset] == '\r') continue;
        if (normalized_index == normalized_offset) return source_offset;
        normalized_index += 1;
    }

    return source.len - 1;
}

test {
    std.testing.refAllDecls(@This());
}

test "require_fmt respects severity" {
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\const foo: u32 = 67;
            \\
        ,
            .{},
            Config{ .severity = severity },
            &.{},
        );

        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\const foo: u32 = 67;
        ,
            .{},
            Config{ .severity = severity },
            &.{.{
                .rule_id = "require_fmt",
                .severity = severity,
                .slice = ";",
                .message = "File is not formatted",
            }},
        );
    }
}

test "require_fmt reports extra whitespace" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const foo  = 67;
        \\
    ,
        .{},
        Config{ .severity = .warning },
        &.{.{
            .rule_id = "require_fmt",
            .severity = .warning,
            .slice = " ",
            .message = "File is not formatted",
        }},
    );
}

test "require_fmt reports missing indentation" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\var x = 1;
        \\}
        \\
    ,
        .{},
        Config{ .severity = .warning },
        &.{.{
            .rule_id = "require_fmt",
            .severity = .warning,
            .slice = "v",
            .message = "File is not formatted",
        }},
    );
}

test "require_fmt severity off suppresses reports" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const foo  : u32 = 67;
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

test "require_fmt ignores invalid ast trees" {
    const rule = buildRule(.{});

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var session = zlinter.testing.initFakeContext(arena.allocator(), std.testing.io);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const doc = try zlinter.testing.loadFakeDocument(
        &session,
        tmp.dir,
        "test.zig",
        "const foo = 1\n", // Missing semicolon
        arena.allocator(),
    );

    try std.testing.expect(doc.tree(&session).errors.len > 0);

    var config = Config{ .severity = .warning };
    const result = try rule.run(
        rule,
        &session,
        doc,
        .{ .config = &config },
    );
    try std.testing.expect(result == null);
}

test "require_fmt ignores crlf line endings when reporting formatting differences" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "//! Comment 1\r\nconst foo:u32 = 67;\r\n",
        .{},
        Config{ .severity = .warning },
        &.{.{
            .rule_id = "require_fmt",
            .severity = .warning,
            .slice = "u",
            .message = "File is not formatted",
        }},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
