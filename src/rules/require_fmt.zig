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

    const fmt = tree.renderAlloc(rule_arena) catch |e| {
        std.log.err("Oh no {t}", .{e});
        return e;
    };

    if (!std.mem.eql(u8, fmt, tree.source)) {
        const diff = firstDifference(fmt, tree.source);
        const source_offset = if (tree.source.len == 0) 0 else @min(diff, tree.source.len - 1);

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

test {
    std.testing.refAllDecls(@This());
}

test "require_fmt" {
    const rule = buildRule(.{});

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            \\const foo: u32 = 67;
            \\
        ,
            .{},
            Config{ .severity = severity },
            &.{},
        );
        try zlinter.testing.testRunRule(
            rule,
            \\const foo: u32 = 67;
        ,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = "require_fmt",
                    .severity = severity,
                    .slice = ";",
                    .message = "File is not formatted",
                },
            },
        );
        try zlinter.testing.testRunRule(
            rule,
            \\const foo  = 67;
            \\
        ,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = "require_fmt",
                    .severity = severity,
                    .slice = " ",
                    .message = "File is not formatted",
                },
            },
        );
        try zlinter.testing.testRunRule(
            rule,
            \\pub fn main() void {
            \\var x = 1;
            \\}
            \\
        ,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = "require_fmt",
                    .severity = severity,
                    .slice = "v",
                    .message = "File is not formatted",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        rule,
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

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
