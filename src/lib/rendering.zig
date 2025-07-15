//! Displaying output to user

pub const LintFileRenderer = struct {
    const Self = @This();

    lines: [][]const u8,

    pub fn init(allocator: std.mem.Allocator, stream: anytype) !Self {
        var lines = std.ArrayListUnmanaged([]const u8).empty;
        defer lines.deinit(allocator);

        const max_line_bytes = 1024 * 1024;
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
                const slice = if (output.len > 0 and output[output.len - 1] == '\r')
                    output[0 .. output.len - 1]
                else
                    output[0..];

                try lines.append(allocator, try allocator.dupe(u8, slice));
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
    inline for (&.{ "\n", "\r\n" }) |newline| {
        const data = "123456789" ++ newline ++ "987654321" ++ newline;
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
}

var printer_singleton: Printer = .{ .verbose = false };
/// Singleton printer for use for the lifetime of the process
pub var process_printer = &printer_singleton;

pub const Printer = struct {
    verbose: bool,
    stdout: ?Writer = null,
    stderr: ?Writer = null,

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
                self.stdout orelse .{ .context = .{ .file = std.fs.File.stdout() } }
            else
                return,
            .err => self.stderr orelse .{ .context = .{ .file = std.fs.File.stderr() } },
            .out => self.stdout orelse .{ .context = .{ .file = std.fs.File.stdout() } },
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
    array: *std.ArrayList(u8),
};

// TODO: remove disable - https://github.com/KurtWagner/zlinter/issues/63
// zlinter-disable-next-line declaration_naming - This looks like a bug in zlinter as error type should be TitleCase
const WriteError = std.fs.File.WriteError || std.mem.Allocator.Error;

const Writer = std.io.GenericWriter(Context, WriteError, writeFn);

fn writeFn(context: Context, bytes: []const u8) WriteError!usize {
    switch (context) {
        .file => |file| return try file.write(bytes),
        .array => |array| {
            try array.appendSlice(bytes);
            return bytes.len;
        },
    }
}

/// Fake output sink for used in tests. See usage of `attachFakeStdoutSink` and
/// `attachFakeStderrSink` for examples
const FakeSink = struct {
    allocator: std.mem.Allocator,
    array_sink: *std.ArrayList(u8),

    fn init(allocator: std.mem.Allocator) error{OutOfMemory}!FakeSink {
        assertTestOnly();

        const array_sink = try allocator.create(std.ArrayList(u8));
        array_sink.* = .init(allocator);

        return .{
            .array_sink = array_sink,
            .allocator = allocator,
        };
    }

    fn writer(self: *FakeSink) Writer {
        return .{ .context = .{ .array = self.array_sink } };
    }

    pub fn output(self: FakeSink) []const u8 {
        return self.array_sink.items[0..];
    }

    pub fn deinit(self: *FakeSink) void {
        self.array_sink.deinit();
        self.allocator.destroy(self.array_sink);
        self.* = undefined;
    }
};

inline fn assertTestOnly() void {
    comptime if (!@import("builtin").is_test) @compileError("Test only");
}

const std = @import("std");
const ansi = @import("ansi.zig");
