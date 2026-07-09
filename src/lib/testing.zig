//! Test only utilities

/// See `runRule` for example (test only)
pub fn loadFakeDocument(
    session: *LintSession,
    dir: std.Io.Dir,
    file_name: []const u8,
    contents: [:0]const u8,
    arena: std.mem.Allocator,
) !*LintDocument {
    assertTestOnly();

    const io = std.testing.io;

    if (std.Io.Dir.path.dirname(file_name)) |dir_name|
        try dir.createDirPath(io, dir_name);

    const file = try dir.createFile(io, file_name, .{});
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    const size = try dir.realPathFile(io, file_name, &buffer);
    const real_path = buffer[0..size];

    var file_buffer: [1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.interface.writeAll(contents);
    try file_writer.interface.flush();

    const file_id = try session.resolveFile(real_path);

    const module_id = session.module_store.resolve(.{
        .root_file = file_id,
        .build_config = .fromIndex(0),
        .build_config_module = @enumFromInt(0),
        .module_id_by_import_name = .empty,
    });

    var has_compile_context = false;
    for (session.compile_contexts.items(.root_module)) |root_module|
        if (root_module == module_id) {
            has_compile_context = true;
            break;
        };
    if (!has_compile_context) {
        _ = session.appendCompileContext(.{
            .root_module = module_id,
            .step_index = @enumFromInt(0),
        });
    }

    const doc = try arena.create(LintDocument);
    try session.initDocument(file_id, arena, doc);
    return doc;
}

pub fn writeFile(dir: std.Io.Dir, file_name: []const u8, contents: []const u8) !void {
    assertTestOnly();

    const io = std.testing.io;

    const file = try dir.createFile(io, file_name, .{});
    defer file.close(io);

    var file_buffer: [2048]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);

    try file_writer.interface.writeAll(contents);
    try file_writer.interface.flush();
}

pub fn initFakeContext(
    arena: std.mem.Allocator,
    io: std.Io,
) LintSession {
    assertTestOnly();

    const fake_args = arena.create(Args) catch @panic("failed to allocate fake args");
    fake_args.* = Args.testDefault();

    const session_arena = arena.create(std.heap.ArenaAllocator) catch @panic("failed to allocate fake session arena");
    session_arena.* = .init(arena);

    const file_arena_allocator = arena.create(std.heap.ArenaAllocator) catch @panic("failed to allocate fake file arena");
    file_arena_allocator.* = .init(arena);

    const rule_arena_allocator = arena.create(std.heap.ArenaAllocator) catch @panic("failed to allocate fake rule arena");
    rule_arena_allocator.* = .init(arena);

    const runtime = arena.create(LintRuntime) catch @panic("failed to allocate fake lint runtime");
    runtime.* = .{
        .io = io,
        .verbose = false,
        .args = fake_args,
        .session_arena = session_arena,
        .file_arena = file_arena_allocator,
        .rule_arena = rule_arena_allocator,
        // TODO: If we really ever need to we can pass zig exe through a build
        // config and evaluate lib dir from `zig env` but I think overkill for
        // our unit tests, so leaving as this for now...
        .zig_exe = "zig",
        .zig_lib_directory = ".",
        .cwd = ".",
    };

    var session: LintSession = .{
        .runtime = runtime,
        .file_store = .init(runtime),
        .module_store = .init(runtime),
        .build_config_store = .init(runtime),
        .type_store = .init(runtime),
        .decl_store = .init(runtime),
    };
    session.init() catch @panic("failed to initialize fake lint session");
    return session;
}

pub const paths = struct {
    /// Comptime join parts using the systems path separator (tests only)
    pub fn join(comptime parts: []const []const u8) []const u8 {
        assertTestOnly();

        if (parts.len == 0) @compileError("Needs at least one part");
        if (parts.len == 1) return parts[0];

        comptime var result: []const u8 = "";
        result = result ++ parts[0];
        inline for (1..parts.len) |i|
            result = result ++ std.Io.Dir.path.sep_str ++ parts[i];
        return result;
    }

    /// Comptime posix path to system path separater convertor (tests only)
    pub fn posix(comptime posix_path: []const u8) []const u8 {
        assertTestOnly();

        @setEvalBranchQuota(10000);

        comptime var result: []const u8 = "";
        inline for (0..posix_path.len) |i|
            result = result ++ std.fmt.comptimePrint("{c}", .{switch (posix_path[i]) {
                std.Io.Dir.path.sep_posix => std.Io.Dir.path.sep,
                else => |c| c,
            }});
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

    for (0..copy_expected.len) |i|
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

/// Expects a single var declaration to be found with a given name and returns it.
///
/// This is for testing to quickly to look up a node in a tree for running
/// tests against it relative to the entire tree.
///
/// This method will return a collision error if more than one var declaration
/// matches the name.
pub fn expectVarDecl(tree: Ast, name: []const u8) !Ast.Node.Index {
    assertTestOnly();

    var found: ?Ast.Node.Index = null;
    var i: u32 = @intFromEnum(Ast.Node.Index.root);
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        if (tree.fullVarDecl(node)) |var_decl| {
            const name_token = var_decl.ast.mut_token + 1;
            if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) {
                if (found != null) return error.TestExpectedSingleVarDeclWithName;
                found = node;
            }
        }
    }

    return found orelse error.TestExpectedVarDeclWithName;
}

/// Expects and returns a the single node matching given tag(s)
///
/// This is to encourage smaller unit tests and to ensure that the order does
/// not matter when asserting. Alternatively use `expectNodeOfTagFirst`
pub fn expectSingleNodeOfTag(tree: Ast, comptime tags: []const Ast.Node.Tag) !Ast.Node.Index {
    assertTestOnly();

    var found: ?Ast.Node.Index = null;
    var i: u32 = @intFromEnum(Ast.Node.Index.root);
    while (i < tree.nodes.len) : (i += 1) {
        const node: Ast.Node.Index = @enumFromInt(i);
        inline for (tags) |tag|
            if (tree.nodeTag(node) == tag) {
                if (found != null) return error.TestExpectedSingleNodeTag;
                found = node;
            };
    }

    return found orelse error.TestExpectedSingleNodeTag;
}

/// Expects at least one node and returns it matching a set of tags
pub fn expectNodeOfTagFirst(
    session: *const LintSession,
    doc: *const LintDocument,
    comptime tags: []const Ast.Node.Tag,
) !Ast.Node.Index {
    assertTestOnly();

    const tree = doc.tree(session);
    var it = try doc.nodeLineageIterator(.root, std.testing.allocator);
    defer it.deinit();

    while (try it.next()) |node_and_children| {
        const node = node_and_children[0];
        inline for (tags) |tag|
            if (tree.nodeTag(node) == tag) {
                return node;
            };
    }
    return error.TestExpectedSingleNodeTag;
}

pub const TestRunOptions = struct {
    filename: []const u8 = "path/to/test.zig",
    allow_parse_errors: bool = false,
};

/// Builds and runs a rule with fake file name and content. Use `testRunRule`
/// which uses this method instead of this method directly.
fn runRule(
    rule: LintRule,
    file_name: []const u8,
    contents: [:0]const u8,
    run_options: RunOptions,
    arena: *std.heap.ArenaAllocator,
    allow_parse_errors: bool,
) !?LintResult {
    assertTestOnly();
    const io = std.testing.io;

    var session = initFakeContext(arena.allocator(), std.testing.io);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const doc = try loadFakeDocument(
        &session,
        tmp.dir,
        file_name,
        contents,
        arena.allocator(),
    );

    const tree = doc.tree(&session);
    if (!allow_parse_errors) {
        std.testing.expectEqual(tree.errors.len, 0) catch |err| {
            std.debug.print("Failed to parse AST:\n{s}\n", .{contents});
            for (tree.errors) |ast_err| {
                var buffer: [1024]u8 = undefined;

                var writer = std.Io.File.stderr().writer(io, &buffer).interface;
                try tree.renderError(ast_err, &writer);
            }
            return err;
        };
    }

    return try rule.run(
        rule,
        &session,
        doc,
        run_options,
    );
}

/// Expectation for problems with "pretty" printing on error that can be
/// copied back into assertions (test only)
fn expectDeepEquals(T: type, expected: []const T, actual: []const T) !void {
    assertTestOnly();

    // TODO: Once we're 0.15.x plus can we just implement fmt methods and use `{f}`?
    if (!std.meta.hasMethod(T, "debugPrint")) @compileError("Type " ++ @typeName(T) + " requires debugPrint method");

    std.testing.expectEqualDeep(expected, actual) catch |e|
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
        };
}

/// Create empty files (test only)
pub fn createFiles(dir: std.Io.Dir, file_paths: [][]const u8) !void {
    assertTestOnly();

    const io = std.testing.io;
    for (file_paths) |file_path| {
        if (std.Io.Dir.path.dirname(file_path)) |parent|
            try dir.createDirPath(io, parent);
        (try dir.createFile(io, file_path, .{})).close(io);
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
    /// When null, notes are ignored. Use &.{} to assert that no notes exist.
    notes: ?[]const []const u8 = null,
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

    pub fn initWithNotes(problem: LintProblem, source: [:0]const u8) Self {
        var expectation = init(problem, source);
        expectation.notes = if (problem.notes) |notes| note_messages: {
            const messages = std.testing.allocator.alloc([]const u8, notes.len) catch @panic("failed to allocate note messages");
            for (notes, 0..) |note, i| messages[i] = note.message;
            break :note_messages messages;
        } else &.{};
        return expectation;
    }

    pub fn deinit(self: *Self) void {
        if (self.notes) |notes| {
            if (notes.len > 0) std.testing.allocator.free(notes);
        }
        self.* = undefined;
    }

    pub fn debugPrint(self: Self, writer: anytype) void {
        writer.print(".{{\n", .{});
        writer.print("  .rule_id = \"{s}\",\n", .{self.rule_id});
        writer.print("  .severity = .@\"{s}\",\n", .{@tagName(self.severity)});

        const has_quote = std.mem.findScalar(u8, self.slice, '"') != null;
        const has_newline = std.mem.findScalar(u8, self.slice, '\n') != null;

        writer.print("  .slice ={s}", .{if (has_newline) "\n" else " "});
        if (has_newline or has_quote) {
            strings.debugPrintMultilineString(self.slice, writer, 2);
        } else {
            writer.print("\"{s}\"", .{self.slice});
        }
        writer.print("{s},\n", .{if (has_newline or has_quote) "\n" else ""});

        writer.print("  .message = \"{s}\",\n", .{self.message});

        if (self.notes) |notes| {
            writer.print("  .notes = &.{{\n", .{});
            for (notes) |note| writer.print("    \"{s}\",\n", .{note});
            writer.print("  }},\n", .{});
        }

        if (self.disabled_by_comment) {
            writer.print("  .disabled_by_comment = {},\n", .{self.disabled_by_comment});
        }

        if (self.fix) |fix| {
            writer.print("  .fix =\n", .{});
            fix.debugPrintWithIndent(writer, 4);
        }

        writer.print("}},\n", .{});
    }
};

/// Runs a given rule with given source input and then expects the actual
/// results to match the problem expectations.
pub fn testRunRule(
    rule: LintRule,
    source: [:0]const u8,
    options: TestRunOptions,
    config: anytype,
    expected: []const LintProblemExpectation,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var local_config = config;
    const run_options: RunOptions = .{ .config = &local_config };
    var result = (try runRule(
        rule,
        options.filename,
        source,
        run_options,
        &arena,
        options.allow_parse_errors,
    ));
    defer if (result) |*r| r.deinit(arena.allocator());

    var actual = std.ArrayList(LintProblemExpectation).empty;
    defer {
        for (actual.items) |*problem| problem.deinit();
        actual.deinit(std.testing.allocator);
    }

    for (if (result) |r| r.problems else &.{}, 0..) |problem, i| {
        const expect_notes = i < expected.len and expected[i].notes != null;
        try actual.append(
            std.testing.allocator,
            if (expect_notes)
                LintProblemExpectation.initWithNotes(problem, source)
            else
                LintProblemExpectation.init(problem, source),
        );
    }

    try expectDeepEquals(LintProblemExpectation, expected, actual.items);
}

const builtin = @import("builtin");
const Args = @import("Args.zig");
const LintDocument = @import("session/LintDocument.zig");
const LintSession = @import("session/LintSession.zig");
const std = @import("std");
const LintRule = @import("rules.zig").LintRule;
const RunOptions = @import("rules.zig").RunOptions;
const LintProblemSeverity = @import("rules.zig").LintProblemSeverity;
const LintProblem = @import("results.zig").LintProblem;
const LintResult = @import("results.zig").LintResult;
const LintProblemFix = @import("results.zig").LintProblemFix;
const strings = @import("strings.zig");
const Ast = std.zig.Ast;
const LintRuntime = @import("session/LintRuntime.zig");

test {
    std.testing.refAllDecls(@This());
}
