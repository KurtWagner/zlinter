//! Displaying output to user

pub const LintFileRenderer = struct {
    const Self = @This();

    source: []const u8,
    line_ends: []usize,

    pub fn init(allocator: std.mem.Allocator, stream: anytype) !Self {
        const source = try stream.readAllAlloc(allocator, max_zig_file_size_bytes);

        var line_ends = try shims.ArrayList(usize).initCapacity(allocator, source.len / 40);
        errdefer line_ends.deinit(allocator);

        for (0..source.len) |i| {
            if (source[i] == '\n')
                try line_ends.append(allocator, i);
        }
        if (source[source.len - 1] != '\n') {
            try line_ends.append(allocator, source.len - 1);
        }

        return .{
            .source = source,
            .line_ends = try line_ends.toOwnedSlice(allocator),
        };
    }

    pub fn getLine(self: Self, line: usize) []const u8 {
        // Given this should only ever be called for a small handful of lines
        // we trim the potential carriage return in here and not during parsing
        // to keep parsing as simple as possible.
        return std.mem.trimRight(u8, if (line == 0)
            self.source[0..self.line_ends[line]]
        else if (line < self.line_ends.len)
            self.source[self.line_ends[line - 1] + 1 .. self.line_ends[line]]
        else
            "", &.{'\r'});
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
        tty: ansi.Tty,
    ) !void {
        for (start_line..end_line + 1) |line_index| {
            const is_start = start_line == line_index;
            const is_end = end_line == line_index;
            const is_middle = !is_start and !is_end;

            if (is_middle) {
                try self.renderLine(
                    line_index,
                    0,
                    if (self.getLine(line_index).len == 0) 0 else self.getLine(line_index).len - 1,
                    writer,
                    tty,
                );
            } else if (is_start and is_end) {
                try self.renderLine(
                    line_index,
                    start_column,
                    end_column,
                    writer,
                    tty,
                );
            } else if (is_start) {
                try self.renderLine(
                    line_index,
                    start_column,
                    if (self.getLine(line_index).len == 0) 0 else self.getLine(line_index).len - 1,
                    writer,
                    tty,
                );
            } else if (is_end) {
                try self.renderLine(
                    line_index,
                    0,
                    end_column,
                    writer,
                    tty,
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
        tty: ansi.Tty,
    ) !void {
        const lhs_format = " {d} ";
        const line_lhs_max_width = comptime std.fmt.comptimePrint(lhs_format, .{std.math.maxInt(@TypeOf(line))}).len;
        var lhs_buffer: [line_lhs_max_width]u8 = undefined;
        const lhs = std.fmt.bufPrint(&lhs_buffer, lhs_format, .{line + 1}) catch unreachable;

        // LHS of code
        try writer.writeAll(tty.ansiOrEmpty(&.{.cyan}));
        try writer.writeAll(lhs);
        try writer.writeAll("| ");
        try writer.writeAll(tty.ansiOrEmpty(&.{.reset}));

        // Actual code
        try writer.writeAll(self.getLine(line));
        try writer.writeByte('\n');

        // LHS of arrows to impacted area
        lhs_buffer = @splat(' ');
        try writer.writeAll(tty.ansiOrEmpty(&.{.gray}));
        try writer.writeAll(lhs_buffer[0..lhs.len]);
        try writer.writeAll("| ");
        try writer.writeAll(tty.ansiOrEmpty(&.{.reset}));

        // Actual arrows
        for (0..column) |_| try writer.writeByte(' ');
        try writer.writeAll(tty.ansiOrEmpty(&.{.bold}));
        for (column..end_column + 1) |_| try writer.writeByte('^');
        try writer.writeAll(tty.ansiOrEmpty(&.{.reset}));
    }

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.line_ends);
        allocator.free(self.source);
    }
};

test "LintFileRenderer" {
    inline for (&.{ "\n", "\r\n" }) |newline| {
        const data = "123456789" ++ newline ++ "987654321" ++ newline;
        var input = std.io.fixedBufferStream(data);

        var renderer = try LintFileRenderer.init(
            std.testing.allocator,
            input.reader(),
        );
        defer renderer.deinit(std.testing.allocator);

        try std.testing.expectEqualStrings("123456789", renderer.getLine(0));
        try std.testing.expectEqualStrings("987654321", renderer.getLine(1));
        try std.testing.expectEqualStrings("", renderer.getLine(2));

        {
            var output = shims.ArrayList(u8).empty;
            defer output.deinit(std.testing.allocator);

            try renderer.render(
                1,
                3,
                1,
                5,
                output.writer(std.testing.allocator),
                .no_color,
            );

            try std.testing.expectEqualStrings(
                \\ 2 | 987654321
                \\   |    ^^^
            , output.items);
        }

        {
            var output = shims.ArrayList(u8).empty;
            defer output.deinit(std.testing.allocator);

            try renderer.render(
                0,
                3,
                1,
                1,
                output.writer(std.testing.allocator),
                .no_color,
            );

            try std.testing.expectEqualStrings(
                \\ 1 | 123456789
                \\   |    ^^^^^^
                \\ 2 | 987654321
                \\   | ^^
            , output.items);
        }
    }
}

var printer_singleton: Printer = .empty;
/// Singleton printer for use for the lifetime of the process
pub var process_printer = &printer_singleton;

pub const Printer = struct {
    verbose: bool,
    stdout: ?Writer = null,
    stderr: ?Writer = null,
    tty: ansi.Tty,

    const empty: Printer = .{ .verbose = false, .tty = .no_color };

    pub fn initAuto(self: *Printer, verbose: bool) void {
        switch (version.zig) {
            .@"0.14" => self.init(
                .{ .context = .{ .file = std.io.getStdOut() } },
                .{ .context = .{ .file = std.io.getStdErr() } },
                .init(std.io.getStdOut()),
                verbose,
            ),
            .@"0.15" => self.init(
                .{ .context = .{ .file = std.fs.File.stdout() } },
                .{ .context = .{ .file = std.fs.File.stderr() } },
                .init(std.fs.File.stdout()),
                verbose,
            ),
        }
    }

    pub fn init(self: *Printer, stdout: Writer, stderr: Writer, tty: ansi.Tty, verbose: bool) void {
        std.debug.assert(self.stdout == null);
        std.debug.assert(self.stderr == null);

        self.stderr = stderr;
        self.stdout = stdout;
        self.tty = tty;
        self.verbose = verbose;
    }

    pub const Kind = enum {
        out,
        verbose,
        err,
    };

    const banner: [60]u8 = @splat('-');

    pub inline fn printBanner(self: Printer, kind: Kind) void {
        return self.println(kind, &banner, .{});
    }

    pub inline fn println(self: Printer, kind: Kind, comptime fmt: []const u8, args: anytype) void {
        return self.print(kind, fmt ++ "\n", args);
    }

    pub fn print(self: Printer, kind: Kind, comptime fmt: []const u8, args: anytype) void {
        var writer: Writer = switch (kind) {
            .verbose => if (self.verbose)
                self.stdout orelse @panic("Requires initAuto or if testing attachFakeStdoutSink")
            else
                return,
            .err => self.stderr orelse @panic("Requires initAuto or if testing attachFakeStderrSink"),
            .out => self.stdout orelse @panic("Requires initAuto or if testing attachFakeStdoutSink"),
        };

        return writer.print(fmt, args) catch |e| {
            std.log.err("Failed to write to std(err|out): {s}", .{@errorName(e)});
            std.log.err("\tOutput: " ++ fmt, args);
        };
    }

    pub fn attachFakeStdoutSink(self: *Printer, allocator: std.mem.Allocator) !FakeSink {
        assertTestOnly();

        var fake = try FakeSink.init(allocator);
        self.stdout = fake.writer();
        return fake;
    }

    pub fn attachFakeStderrSink(self: *Printer, allocator: std.mem.Allocator) !FakeSink {
        assertTestOnly();

        var fake = try FakeSink.init(allocator);
        self.stderr = fake.writer();
        return fake;
    }
};

/// Context resources are not owned by the writer so the caller needs to
/// ensure they're cleaned up properly afterwards.
const Context = union(enum) {
    file: std.fs.File,
    array: struct { allocator: std.mem.Allocator, backing: *shims.ArrayList(u8) },
};

const WriteError = std.fs.File.WriteError || std.mem.Allocator.Error;
const Writer = std.io.GenericWriter(Context, WriteError, writeFn);

fn writeFn(context: Context, bytes: []const u8) WriteError!usize {
    switch (context) {
        .file => |file| return try file.write(bytes),
        .array => |array| {
            try array.backing.appendSlice(array.allocator, bytes);
            return bytes.len;
        },
    }
}

/// Fake output sink for used in tests. See usage of `attachFakeStdoutSink` and
/// `attachFakeStderrSink` for examples
const FakeSink = struct {
    allocator: std.mem.Allocator,
    array_sink: *shims.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) error{OutOfMemory}!FakeSink {
        assertTestOnly();

        const array_sink = try allocator.create(shims.ArrayList(u8));
        array_sink.* = .empty;

        return .{
            .array_sink = array_sink,
            .allocator = allocator,
        };
    }

    fn writer(self: *FakeSink) Writer {
        return .{ .context = .{ .array = .{ .allocator = self.allocator, .backing = self.array_sink } } };
    }

    pub fn output(self: FakeSink) []const u8 {
        return self.array_sink.items[0..];
    }

    pub fn deinit(self: *FakeSink) void {
        self.array_sink.deinit(self.allocator);
        self.allocator.destroy(self.array_sink);
        self.* = undefined;
    }
};

inline fn assertTestOnly() void {
    comptime if (!@import("builtin").is_test) @compileError("Test only");
}

const std = @import("std");
const ansi = @import("ansi.zig");
const max_zig_file_size_bytes = @import("session.zig").max_zig_file_size_bytes;
const version = @import("version.zig");
const shims = @import("shims.zig");
