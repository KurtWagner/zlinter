//! Test only utilities

/// See `runRule` for example (test only)
pub fn loadFakeDocument(ctx: *LintContext, dir: std.fs.Dir, file_name: []const u8, contents: [:0]const u8, arena: std.mem.Allocator) !?LintDocument {
    assertTestOnly();

    if (std.fs.path.dirname(file_name)) |dir_name|
        try dir.makePath(dir_name);

    const file = try dir.createFile(file_name, .{});
    defer file.close();

    var buffer: [2024]u8 = undefined;
    const real_path = try dir.realpath(file_name, &buffer);

    try file.writeAll(contents);

    return (try ctx.loadDocument(real_path, ctx.gpa, arena)).?;
}

pub const paths = struct {
    /// Comptime join parts using the systems path separator (tests only)
    pub fn join(comptime parts: []const []const u8) []const u8 {
        assertTestOnly();

        if (parts.len == 0) @compileError("Needs at least one part");
        if (parts.len == 1) return parts[0];

        comptime var result: []const u8 = "";
        result = result ++ parts[0];
        inline for (1..parts.len) |i| {
            result = result ++ std.fs.path.sep_str ++ parts[i];
        }
        return result;
    }

    /// Comptime posix path to system path separater convertor (tests only)
    pub fn posix(comptime posix_path: []const u8) []const u8 {
        assertTestOnly();

        comptime var result: []const u8 = "";
        inline for (0..posix_path.len) |i| {
            result = result ++ std.fmt.comptimePrint("{c}", .{switch (posix_path[i]) {
                std.fs.path.sep_posix => std.fs.path.sep,
                else => |c| c,
            }});
        }
        return result;
    }
};

pub fn expectContainsExactlyStrings(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);

    const copy_expected = try std.testing.allocator.dupe([]const u8, expected);
    defer std.testing.allocator.free(copy_expected);

    const copy_actual = try std.testing.allocator.dupe([]const u8, actual);
    defer std.testing.allocator.free(copy_actual);

    const comparators = struct {
        pub fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    };

    std.mem.sort([]const u8, copy_expected, {}, comparators.stringLessThan);
    std.mem.sort([]const u8, copy_actual, {}, comparators.stringLessThan);

    for (0..copy_expected.len) |i| {
        std.testing.expectEqualStrings(copy_expected[i], copy_actual[i]) catch |e| {
            std.log.err("Expected {s} to contain {s}", .{ copy_actual, copy_expected });
            return e;
        };
    }
}

/// Builds and runs a rule with fake file name and content (test only)
pub fn runRule(rule: LintRule, file_name: []const u8, contents: [:0]const u8, options: LintOptions) !?LintResult {
    assertTestOnly();

    var ctx: LintContext = undefined;
    try ctx.init(.{}, std.testing.allocator);
    defer ctx.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var doc = (try loadFakeDocument(
        &ctx,
        tmp.dir,
        file_name,
        contents,
        arena.allocator(),
    )).?;
    defer doc.deinit(ctx.gpa);

    const ast = doc.handle.tree;
    std.testing.expectEqual(ast.errors.len, 0) catch |err| {
        std.debug.print("Failed to parse AST:\n", .{});
        for (ast.errors) |ast_err| {
            try ast.renderError(ast_err, std.io.getStdErr().writer());
        }
        return err;
    };

    return try rule.run(
        rule,
        ctx,
        doc,
        std.testing.allocator,
        options,
    );
}

/// Expectation for problems with "pretty" printing on error that can be
/// copied back into assertions (test only)
pub fn expectProblemsEqual(expected: []const LintProblem, actual: []LintProblem) !void {
    assertTestOnly();

    std.testing.expectEqualDeep(expected, actual) catch |e| {
        switch (e) {
            error.TestExpectedEqual => {
                std.debug.print(
                    \\--------------------------------------------------
                    \\ Actual Lint Problems:
                    \\--------------------------------------------------
                    \\
                , .{});

                for (actual) |problem| problem.debugPrint(std.debug);
                std.debug.print("--------------------------------------------------\n", .{});

                return e;
            },
        }
    };
}

/// Expectation for problems with "pretty" printing on error that can be
/// copied back into assertions (test only)
pub fn expectDeepEquals(T: type, expected: []const T, actual: []const T) !void {
    assertTestOnly();

    // TODO: Once we're 0.15.x plus can we just implement fmt methods and use `{f}`?
    if (!std.meta.hasMethod(T, "debugPrint")) @compileError("Type " ++ @typeName(T) + " requires debugPrint method");

    std.testing.expectEqualDeep(expected, actual) catch |e| {
        switch (e) {
            error.TestExpectedEqual => {
                std.debug.print(
                    \\--------------------------------------------------
                    \\ Actual:
                    \\--------------------------------------------------
                    \\
                , .{});

                for (actual) |problem| problem.debugPrint(std.debug);
                std.debug.print("--------------------------------------------------\n", .{});

                return e;
            },
        }
    };
}

/// Create empty files (test only)
pub fn createFiles(dir: std.fs.Dir, file_paths: [][]const u8) !void {
    assertTestOnly();

    for (file_paths) |file_path| {
        if (std.fs.path.dirname(file_path)) |parent|
            try dir.makePath(parent);
        (try dir.createFile(file_path, .{})).close();
    }
}

inline fn assertTestOnly() void {
    comptime if (!builtin.is_test) @compileError("Test only");
}

pub const LintProblemExpectation = struct {
    const Self = @This();

    rule_id: []const u8,
    severity: LintProblemSeverity,
    slice: []const u8,

    message: []const u8,
    disabled_by_comment: bool = false,
    fix: ?LintProblemFix = null,

    pub fn init(problem: LintProblem, source: [:0]const u8) Self {
        return .{
            .rule_id = problem.rule_id,
            .severity = problem.severity,
            .slice = problem.sliceSource(source),
            .message = problem.message,
            .disabled_by_comment = problem.disabled_by_comment,
            .fix = problem.fix,
        };
    }

    pub fn debugPrint(self: Self, writer: anytype) void {
        writer.print(".{{\n", .{});
        writer.print("  .rule_id = \"{s}\",\n", .{self.rule_id});
        writer.print("  .severity = .@\"{s}\",\n", .{@tagName(self.severity)});
        writer.print("  .slice = \"{s}\",\n", .{self.slice});
        writer.print("  .message = \"{s}\",\n", .{self.message});
        writer.print("  .disabled_by_comment = {?},\n", .{self.disabled_by_comment});

        if (self.fix) |fix| {
            writer.print("  .fix =\n", .{});
            fix.debugPrintWithIndent(writer, 4);
        } else {
            writer.print("  .fix = null,\n", .{});
        }

        writer.print("}},\n", .{});
    }
};

/// Runs a given rule with given source input and then expects the actual
/// results to match the problem expectations.
pub fn testRunRule(
    rule: LintRule,
    source: [:0]const u8,
    config: anytype,
    expected: []const LintProblemExpectation,
) !void {
    var local_config = config;
    var result = (try runRule(
        rule,
        paths.posix("path/to/test.zig"),
        source,
        .{ .config = &local_config },
    ));
    defer if (result) |*r| r.deinit(std.testing.allocator);

    var actual = std.ArrayList(LintProblemExpectation).init(std.testing.allocator);
    defer actual.deinit();

    for (if (result) |r| r.problems else &.{}) |problem| {
        try actual.append(LintProblemExpectation.init(problem, source));
    }

    try expectDeepEquals(LintProblemExpectation, expected, actual.items);
}

const builtin = @import("builtin");
const std = @import("std");
const LintContext = @import("session.zig").LintContext;
const LintDocument = @import("session.zig").LintDocument;
const LintRule = @import("rules.zig").LintRule;
const LintProblemSeverity = @import("rules.zig").LintProblemSeverity;
const LintProblem = @import("results.zig").LintProblem;
const LintResult = @import("results.zig").LintResult;
const LintProblemFix = @import("results.zig").LintProblemFix;
const LintOptions = @import("session.zig").LintOptions;
