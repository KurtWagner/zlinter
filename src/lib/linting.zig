//! Linting stuff

/// A loaded and parsed zig file that is given to zig lint rules.
pub const LintDocument = struct {
    path: []const u8,
    handle: *zls.DocumentStore.Handle,
    analyser: *zls.Analyser,

    pub fn deinit(self: *LintDocument, gpa: std.mem.Allocator) void {
        self.analyser.deinit();
        gpa.destroy(self.analyser);
        gpa.free(self.path);
    }

    pub inline fn resolveTypeOfNode(self: @This(), node: std.zig.Ast.Node.Index) !?zls.Analyser.Type {
        return switch (version.zig) {
            .@"0.15" => self.analyser.resolveTypeOfNode(.of(node, self.handle)),
            .@"0.14" => self.analyser.resolveTypeOfNode(.{ .handle = self.handle, .node = node }),
        };
    }
};

/// The context of all document and rule executions.
pub const LintContext = struct {
    thread_pool: if (builtin.single_threaded) void else std.Thread.Pool,
    diagnostics_collection: zls.DiagnosticsCollection,
    intern_pool: zls.analyser.InternPool,
    document_store: zls.DocumentStore,
    gpa: std.mem.Allocator,

    pub fn init(self: *LintContext, config: zls.Config, gpa: std.mem.Allocator) !void {
        self.* = .{
            .gpa = gpa,
            .diagnostics_collection = .{ .allocator = gpa },
            .intern_pool = try .init(gpa),
            .thread_pool = undefined, // set below.
            .document_store = undefined, // set below.
        };

        if (!builtin.single_threaded) {
            self.thread_pool.init(.{
                .allocator = gpa,
                .n_jobs = @min(4, std.Thread.getCpuCount() catch 1),
            }) catch @panic("Failed to init thread pool");
        }
        self.document_store = zls.DocumentStore{
            .allocator = gpa,
            .diagnostics_collection = &self.diagnostics_collection,
            .config = switch (version.zig) {
                .@"0.15" => .{
                    .zig_exe_path = config.zig_exe_path,
                    .zig_lib_dir = dir: {
                        if (config.zig_lib_path) |zig_lib_path| {
                            if (std.fs.openDirAbsolute(zig_lib_path, .{})) |zig_lib_dir| {
                                break :dir .{
                                    .handle = zig_lib_dir,
                                    .path = zig_lib_path,
                                };
                            } else |err| {
                                std.log.err("failed to open zig library directory '{s}': {s}", .{ zig_lib_path, @errorName(err) });
                            }
                        }
                        break :dir null;
                    },
                    .build_runner_path = config.build_runner_path,
                    .builtin_path = config.builtin_path,
                    .global_cache_dir = dir: {
                        if (config.global_cache_path) |global_cache_path| {
                            if (std.fs.openDirAbsolute(global_cache_path, .{})) |global_cache_dir| {
                                break :dir .{
                                    .handle = global_cache_dir,
                                    .path = global_cache_path,
                                };
                            } else |err| {
                                std.log.err("failed to open zig library directory '{s}': {s}", .{ global_cache_path, @errorName(err) });
                            }
                        }
                        break :dir null;
                    },
                },
                .@"0.14" => .fromMainConfig(config),
            },

            .thread_pool = &self.thread_pool,
        };
    }

    pub fn deinit(self: *LintContext) void {
        self.diagnostics_collection.deinit();
        self.intern_pool.deinit(self.gpa);
        self.document_store.deinit();
        if (!builtin.single_threaded) self.thread_pool.deinit();
    }

    /// Loads and parses zig file into the document store.
    ///
    /// Caller is responsible for calling deinit once done.
    pub fn loadDocument(self: *LintContext, path: []const u8, gpa: std.mem.Allocator, arena: std.mem.Allocator) !?LintDocument {
        var mem: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&mem);
        const uri = try zls.URI.fromPath(
            fba.allocator(),
            std.fs.cwd().realpathAlloc(
                fba.allocator(),
                path,
            ) catch {
                std.log.err("Failed to create real path for: {s}", .{path});
                return null;
            },
        );

        const handle = self.document_store.getOrLoadHandle(uri) orelse return null;
        const doc: LintDocument = .{
            .path = try gpa.dupe(u8, path),
            .handle = handle,
            .analyser = try gpa.create(zls.Analyser),
        };

        doc.analyser.* = switch (version.zig) {
            .@"0.14" => zls.Analyser.init(
                gpa,
                &self.document_store,
                &self.intern_pool,
                handle,
            ),
            .@"0.15" => zls.Analyser.init(
                gpa,
                arena,
                &self.document_store,
                &self.intern_pool,
                handle,
            ),
        };
        return doc;
    }
};

pub const LintOptions = struct {
    config: ?*anyopaque = null,

    pub inline fn getConfig(self: @This(), T: type) T {
        return if (self.config) |config| @as(*T, @ptrCast(@alignCast(config))).* else T{};
    }
};

/// A linter rule with a unique id and a run method.
pub const LintRule = struct {
    rule_id: []const u8,
    run: *const fn (
        self: LintRule,
        ctx: LintContext,
        doc: LintDocument,
        allocator: std.mem.Allocator,
        options: LintOptions,
    ) error{OutOfMemory}!?LintResult,
};

/// Rules the modify the execution of rules.
pub const LintRuleOptions = struct {}; // zlinter-disable-current-line

/// Location of a source file to lint
pub const LintFile = struct {
    /// Path to the file relative to the execution of the linter. This memory
    /// is owned and free'd in `deinit`.
    pathname: []const u8,

    pub fn init(allocator: std.mem.Allocator, pathname: []const u8) error{OutOfMemory}!LintFile {
        return .{ .pathname = try allocator.dupe(u8, pathname) };
    }

    pub fn deinit(self: *LintFile, allocator: std.mem.Allocator) void {
        allocator.free(self.pathname);
    }
};

pub fn isLintableFilePath(file_path: []const u8) bool {
    // TODO: Should we support gitignore parsing?
    const extension = ".zig";

    const basename = std.fs.path.basename(file_path);
    if (basename.len <= extension.len) return false;
    if (!std.mem.endsWith(u8, basename, extension)) return false;

    var components = try std.fs.path.componentIterator(file_path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".zig-cache")) return false;
        if (std.mem.eql(u8, component.name, "zig-out")) return false;
    }

    return true;
}

test "isLintableFilePath" {
    // Good:
    try std.testing.expect(isLintableFilePath("a.zig"));
    try std.testing.expect(isLintableFilePath("file.zig"));
    try std.testing.expect(isLintableFilePath("some/path/file.zig"));
    try std.testing.expect(isLintableFilePath("./some/path/file.zig"));

    // Bad extensions:
    try std.testing.expect(!isLintableFilePath(".zig"));
    try std.testing.expect(!isLintableFilePath("file.zi"));
    try std.testing.expect(!isLintableFilePath("file.z"));
    try std.testing.expect(!isLintableFilePath("file."));
    try std.testing.expect(!isLintableFilePath("zig"));
    try std.testing.expect(!isLintableFilePath("src/.zig"));
    try std.testing.expect(!isLintableFilePath("src/zig"));

    // Bad parent directory
    try std.testing.expect(!isLintableFilePath("zig-out/file.zig"));
    try std.testing.expect(!isLintableFilePath("./zig-out/file.zig"));
    try std.testing.expect(!isLintableFilePath(".zig-cache/file.zig"));
    try std.testing.expect(!isLintableFilePath("./parent/.zig-cache/file.zig"));
    try std.testing.expect(!isLintableFilePath("/other/parent/.zig-cache/file.zig"));
}

pub const LintFileRenderer = struct {
    const Self = @This();

    lines: [][]const u8,

    pub fn init(allocator: std.mem.Allocator, stream: anytype) !Self {
        var lines = std.ArrayListUnmanaged([]const u8).empty;
        defer lines.deinit(allocator);

        const max_line_bytes = 64 * 1024;
        var buf: [max_line_bytes]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        while (true) {
            fbs.reset();
            if (stream.streamUntilDelimiter(
                fbs.writer(),
                '\n',
                fbs.buffer.len,
            )) {
                const output = fbs.getWritten();
                try lines.append(allocator, try allocator.dupe(u8, output));
            } else |err| switch (err) {
                error.EndOfStream => {
                    if (fbs.getWritten().len == 0) {
                        try lines.append(allocator, try allocator.dupe(u8, ""));
                    }
                    break;
                },
                else => |e| return e,
            }
        }

        return .{ .lines = try lines.toOwnedSlice(allocator) };
    }

    /// Renders a given line with a span highlighted with "^" below the line.
    /// The column values are inclusive of "^". e.g., start 0 and end 1 will
    /// put "^" under column 0 and 1. The output will not include a trailing
    /// newline.
    pub fn render(
        self: Self,
        start_line: usize,
        start_column: usize,
        end_line: usize,
        end_column: usize,
        writer: anytype,
    ) !void {
        for (start_line..end_line + 1) |line_index| {
            const is_start = start_line == line_index;
            const is_end = end_line == line_index;
            const is_middle = !is_start and !is_end;

            if (is_middle) {
                try self.renderLine(
                    line_index,
                    0,
                    if (self.lines[line_index].len == 0) 0 else self.lines[line_index].len - 1,
                    writer,
                );
            } else if (is_start and is_end) {
                try self.renderLine(
                    line_index,
                    start_column,
                    end_column,
                    writer,
                );
            } else if (is_start) {
                try self.renderLine(
                    line_index,
                    start_column,
                    if (self.lines[line_index].len == 0) 0 else self.lines[line_index].len - 1,
                    writer,
                );
            } else if (is_end) {
                try self.renderLine(
                    line_index,
                    0,
                    end_column,
                    writer,
                );
            } else {
                @panic("No possible");
            }

            if (!is_end) {
                try writer.writeByte('\n');
            }
        }
    }

    fn renderLine(
        self: Self,
        line: usize,
        column: usize,
        end_column: usize,
        writer: anytype,
    ) !void {
        const lhs_format = " {d} ";
        const line_lhs_max_width = comptime std.fmt.comptimePrint(lhs_format, .{std.math.maxInt(@TypeOf(line))}).len;
        var lhs_buffer: [line_lhs_max_width]u8 = undefined;
        const lhs = std.fmt.bufPrint(&lhs_buffer, lhs_format, .{line + 1}) catch unreachable;

        // LHS of code
        try writer.writeAll(ansi.get(&.{.cyan}));
        try writer.writeAll(lhs);
        try writer.writeAll("| ");
        try writer.writeAll(ansi.get(&.{.reset}));

        // Actual code
        try writer.writeAll(self.lines[line]);
        try writer.writeByte('\n');

        // LHS of arrows to impacted area
        lhs_buffer = @splat(' ');
        try writer.writeAll(ansi.get(&.{.gray}));
        try writer.writeAll(lhs_buffer[0..lhs.len]);
        try writer.writeAll("| ");
        try writer.writeAll(ansi.get(&.{.reset}));

        // Actual arrows
        for (0..column) |_| try writer.writeByte(' ');
        try writer.writeAll(ansi.get(&.{.bold}));
        for (column..end_column + 1) |_| try writer.writeByte('^');
        try writer.writeAll(ansi.get(&.{.reset}));
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        for (self.lines) |line| allocator.free(line);
        allocator.free(self.lines);
    }
};

test "LintFileRenderer" {
    const data = "123456789\n987654321\n";
    var input = std.io.fixedBufferStream(data);

    var renderer = try LintFileRenderer.init(
        std.testing.allocator,
        input.reader(),
    );
    defer renderer.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(&[3][]const u8{
        "123456789",
        "987654321",
        "",
    }, renderer.lines);

    {
        var output = std.ArrayListUnmanaged(u8).empty;
        defer output.deinit(std.testing.allocator);

        try renderer.render(
            1,
            3,
            1,
            5,
            output.writer(std.testing.allocator),
        );

        try std.testing.expectEqualStrings(
            \\ 2 | 987654321
            \\   |    ^^^
        , output.items);
    }

    {
        var output = std.ArrayListUnmanaged(u8).empty;
        defer output.deinit(std.testing.allocator);

        try renderer.render(
            0,
            3,
            1,
            1,
            output.writer(std.testing.allocator),
        );

        try std.testing.expectEqualStrings(
            \\ 1 | 123456789
            \\   |    ^^^^^^
            \\ 2 | 987654321
            \\   | ^^
        , output.items);
    }
}

pub const LintTextStyleWithSeverity = struct {
    style: LintTextStyle,
    severity: LintProblemSeverity,

    pub const off = LintTextStyleWithSeverity{
        .style = .off,
        .severity = .off,
    };
};

pub const LintTextStyle = enum {
    /// No style check - can be any style
    off,
    /// e.g., TitleCase
    title_case,
    /// e.g., snake_case
    snake_case,
    /// e.g., camelCase
    camel_case,

    pub inline fn check(self: LintTextStyle, content: []const u8) bool {
        std.debug.assert(content.len > 0);

        return switch (self) {
            .off => true,
            .snake_case => !strings.containsUpper(content),
            .title_case => strings.isCapitalized(content) and !strings.containsUnderscore(content),
            .camel_case => !strings.isCapitalized(content) and !strings.containsUnderscore(content),
        };
    }

    test "check" {
        // Off:
        inline for (&.{ "snake_case", "camelCase", "TitleCase", "a", "A" }) |content| {
            try std.testing.expect(LintTextStyle.off.check(content));
        }

        // Snake case:
        inline for (&.{ "snake_case", "a", "a_b_c" }) |content| {
            try std.testing.expect(LintTextStyle.snake_case.check(content));
        }

        // Title case:
        inline for (&.{ "TitleCase", "A", "AB" }) |content| {
            try std.testing.expect(LintTextStyle.title_case.check(content));
        }

        // Camel case:
        inline for (&.{ "camelCase", "a", "aB" }) |content| {
            try std.testing.expect(LintTextStyle.camel_case.check(content));
        }
    }

    pub inline fn name(self: LintTextStyle) []const u8 {
        return switch (self) {
            .off => @panic("Style is off so we should never get its name"),
            .snake_case => "snake_case",
            .title_case => "TitleCase",
            .camel_case => "camelCase",
        };
    }
};

pub const LintProblemSeverity = enum {
    /// Exit zero
    off,
    /// Exit zero with warning
    warning,
    /// Exit non-zero
    @"error",

    pub inline fn name(
        self: LintProblemSeverity,
        buffer: *[32]u8,
        options: struct { ansi: bool = false },
    ) []const u8 {
        const prefix = if (options.ansi)
            switch (self) {
                .off => unreachable,
                .warning => ansi.get(&.{ .bold, .yellow }),
                .@"error" => ansi.get(&.{ .bold, .red }),
            }
        else
            "";

        const suffix = if (options.ansi) ansi.get(&.{.reset}) else "";

        return switch (self) {
            .off => unreachable,
            .warning => std.fmt.bufPrint(buffer, "{s}warning{s}", .{ prefix, suffix }) catch unreachable,
            .@"error" => std.fmt.bufPrint(buffer, "{s}error{s}", .{ prefix, suffix }) catch unreachable,
        };
    }
};

/// Result from running a lint rule.
pub const LintResult = struct {
    const Self = @This();

    file_path: []const u8,
    problems: []LintProblem,

    /// Initializes a result. Caller must call deinit once done to free memory.
    pub fn init(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        problems: []LintProblem,
    ) error{OutOfMemory}!Self {
        return .{
            .file_path = try allocator.dupe(u8, file_path),
            .problems = problems,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.problems) |err| {
            allocator.free(err.message);
        }
        allocator.free(self.problems);
        allocator.free(self.file_path);
    }
};

pub const LintProblemLocation = struct {
    /// Location in entire source
    offset: usize,
    /// Line number in source (index zero)
    line: usize,
    /// Column on line in source (index zero)
    column: usize,

    pub const zero: LintProblemLocation = .{
        .offset = 0,
        .line = 0,
        .column = 0,
    };

    pub fn startOfNode(tree: std.zig.Ast, index: std.zig.Ast.Node.Index) LintProblemLocation {
        const first_token_loc = tree.tokenLocation(0, tree.firstToken(index));
        return .{
            .offset = first_token_loc.line_start,
            .line = first_token_loc.line,
            .column = first_token_loc.column,
        };
    }

    pub fn endOfNode(tree: std.zig.Ast, index: std.zig.Ast.Node.Index) LintProblemLocation {
        const last_token = tree.lastToken(index);
        const last_token_loc = tree.tokenLocation(0, last_token);
        return .{
            .offset = last_token_loc.line_end,
            .line = last_token_loc.line,
            .column = last_token_loc.column + tree.tokenSlice(last_token).len,
        };
    }

    pub fn startOfToken(tree: std.zig.Ast, index: std.zig.Ast.TokenIndex) LintProblemLocation {
        const loc = tree.tokenLocation(0, index);
        return .{
            .offset = loc.line_start,
            .line = loc.line,
            .column = loc.column,
        };
    }

    pub fn endOfToken(tree: std.zig.Ast, index: std.zig.Ast.TokenIndex) LintProblemLocation {
        const loc = tree.tokenLocation(0, index);
        return .{
            .offset = loc.line_end,
            .line = loc.line,
            .column = loc.column + tree.tokenSlice(index).len - 1,
        };
    }

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = undefined;
        @memset(&spaces, ' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .offset = {d},\n", .{ indent_str, self.offset });
        writer.print("{s}  .line = {d},\n", .{ indent_str, self.line });
        writer.print("{s}  .column = {d},\n", .{ indent_str, self.column });
        writer.print("{s}}},\n", .{indent_str});
    }
};

pub const LintProblem = struct {
    const Self = @This();

    rule_id: []const u8,
    severity: LintProblemSeverity,
    start: LintProblemLocation,
    end: LintProblemLocation,

    message: []const u8,
    disabled_by_comment: bool = false,
    fix: ?LintProblemFix = null,

    pub fn sliceSource(self: Self, source: [:0]const u8) []const u8 {
        return source[self.start.offset..self.end.offset];
    }

    pub fn debugPrint(self: Self, writer: anytype) void {
        writer.print(".{{\n", .{});
        writer.print("  .rule_id = \"{s}\",\n", .{self.rule_id});
        writer.print("  .severity = .@\"{s}\",\n", .{@tagName(self.severity)});
        writer.print("  .start =\n", .{});
        self.start.debugPrintWithIndent(writer, 4);

        writer.print("  .end =\n", .{});
        self.end.debugPrintWithIndent(writer, 4);

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

pub const LintProblemFix = struct {
    start: usize,
    end: usize,
    text: []const u8,

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = undefined;
        @memset(&spaces, ' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .start = {d},\n", .{ indent_str, self.start });
        writer.print("{s}  .end = {d},\n", .{ indent_str, self.end });
        writer.print("{s}  .text = \"{s}\",\n", .{ indent_str, self.text });
        writer.print("{s}}},\n", .{indent_str});
    }
};

// ----------------------------------------------------------------------------
// Test helpers:
// ----------------------------------------------------------------------------

pub const testing = struct {
    /// Builds and runs a rule with fake file name and content.
    pub fn runRule(rule: LintRule, file_path: []const u8, contents: [:0]const u8) !?LintResult {
        assertTestOnly();

        var ctx: LintContext = undefined;
        try ctx.init(.{}, std.testing.allocator);
        defer ctx.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        if (std.fs.path.dirname(file_path)) |dir_name|
            try tmp.dir.makePath(dir_name);

        const file = try tmp.dir.createFile(file_path, .{});
        defer file.close();

        var buffer: [2024]u8 = undefined;
        const real_path = try tmp.dir.realpath(file_path, &buffer);

        try file.writeAll(contents);

        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var doc = (try ctx.loadDocument(real_path, ctx.gpa, arena.allocator())).?;
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

    inline fn assertTestOnly() void {
        comptime if (!@import("builtin").is_test) @compileError("Test only");
    }
};

const std = @import("std");
const builtin = @import("builtin");
const zls = @import("zls");
const strings = @import("strings.zig");
const version = @import("version.zig");
const ansi = @import("ansi.zig");
