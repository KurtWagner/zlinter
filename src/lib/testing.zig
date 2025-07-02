/// See `testing.runRule` for example
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

/// Builds and runs a rule with fake file name and content.
pub fn runRule(rule: LintRule, file_name: []const u8, contents: [:0]const u8) !?LintResult {
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
        .{},
    );
}

/// Expectation for problems with "pretty" printing on error that can be
/// copied back into assertions.
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

const builtin = @import("builtin");
const std = @import("std");
const LintContext = @import("linting.zig").LintContext;
const LintDocument = @import("linting.zig").LintDocument;
const LintRule = @import("linting.zig").LintRule;
const LintProblem = @import("linting.zig").LintProblem;
const LintResult = @import("linting.zig").LintResult;
