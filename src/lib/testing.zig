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

        @setEvalBranchQuota(10000);

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
            std.log.err("Expected: &.{{", .{});
            for (copy_expected) |str| std.log.err("  \"{s}\"", .{str});
            std.log.err("}};", .{});

            std.log.err("Actual: &.{{", .{});
            for (copy_actual) |str| std.log.err("  \"{s}\"", .{str});
            std.log.err("}};", .{});

            return e;
        };
    }
}

/// Test that asserts an array of node indexes match another by using node source
/// slices to make the assertion more human readable.
///
/// This assumes that node sources are unique, which should be the case for unit
/// tests.
pub fn expectNodeSlices(
    expected: []const []const u8,
    tree: Ast,
    actual: []const Ast.Node.Index,
) !void {
    assertTestOnly();

    if (expected.len != actual.len) {
        std.debug.print("Expected {d} nodes, got {d}\n", .{ expected.len, actual.len });
        return error.TestExpectedEqual;
    }

    for (expected, 0..) |expected_slice, i| {
        const actual_slice = tree.getNodeSource(actual[i]);

        if (!std.mem.eql(u8, actual_slice, expected_slice)) {
            std.debug.print("Mismatch at index {d}:\n", .{i});
            std.debug.print("  Expected: \"{s}\"\n", .{expected_slice});
            std.debug.print("    Actual: \"{s}\"\n", .{actual_slice});
            return error.TestExpectedEqual;
        }
    }
}

/// Expects and returns a the single node matching given tag(s)
///
/// This is to encourage smaller unit tests and to ensure that the order does
/// not matter when asserting. Alternatively use `expectNodeOfTagFirst`
pub fn expectSingleNodeOfTag(tree: Ast, comptime tags: []const Ast.Node.Tag) !Ast.Node.Index {
    assertTestOnly();

    var found: ?Ast.Node.Index = null;
    var i = NodeIndexShim.root;
    while (i.index < tree.nodes.len) : (i.index += 1) {
        inline for (tags) |tag| {
            if (nodeTag(tree, i.toNodeIndex()) == tag) {
                if (found != null) return error.TestExpectedSingleNodeTag;
                found = i.toNodeIndex();
            }
        }
    }

    return found orelse error.TestExpectedSingleNodeTag;
}

/// Expects at least one node and returns it matching a set of tags
pub fn expectNodeOfTagFirst(doc: LintDocument, comptime tags: []const Ast.Node.Tag) !Ast.Node.Index {
    assertTestOnly();

    var it = try doc.nodeLineageIterator(.root, std.testing.allocator);
    defer it.deinit();

    while (try it.next()) |node_and_children| {
        const node = node_and_children[0].toNodeIndex();
        inline for (tags) |tag| {
            if (nodeTag(doc.handle.tree, node) == tag) {
                return node;
            }
        }
    }
    return error.TestExpectedSingleNodeTag;
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

    const tree = doc.handle.tree;
    std.testing.expectEqual(tree.errors.len, 0) catch |err| {
        std.debug.print("Failed to parse AST:\n", .{});
        for (tree.errors) |ast_err| {
            var buffer: [1024]u8 = undefined;

            var writer = std.fs.File.stderr().writer(&buffer).interface;
            try tree.renderError(ast_err, &writer);
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

        writer.print("  .slice = \n", .{});
        strings.debugPrintMultilineString(self.slice, writer, 2);
        writer.print("\n,\n", .{});

        writer.print("  .message = \"{s}\",\n", .{self.message});
        writer.print("  .disabled_by_comment = {},\n", .{self.disabled_by_comment});

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
const NodeIndexShim = @import("shims.zig").NodeIndexShim;
const nodeTag = @import("shims.zig").nodeTag;
const strings = @import("strings.zig");
const Ast = std.zig.Ast;
