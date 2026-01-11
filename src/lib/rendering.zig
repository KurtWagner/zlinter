//! Displaying output to user

pub const LintFileRenderer = struct {
    const Self = @This();

    source: []const u8,
    line_ends: []usize,

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !Self {
        const source = try reader.allocRemaining(allocator, .limited(max_zig_file_size_bytes));

        var line_ends = try std.ArrayList(usize).initCapacity(allocator, source.len / 40);
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

    /// Returns the line and column (both zero indexed) of a given byte offset
    /// in the file being rendered.
    pub fn lineAndColumn(self: Self, byte_offset: usize) struct { usize, usize } {
        std.debug.assert(byte_offset < self.source.len);
        const line = self.lineNumber(byte_offset);
        return .{ line, self.columnNumber(line, byte_offset) };
    }

    fn lineNumber(self: Self, byte_offset: usize) usize {
        for (self.line_ends, 0..) |line_end, i| {
            if (byte_offset <= line_end) return i;
        }
        return self.line_ends.len;
    }

    fn columnNumber(self: Self, line: usize, byte_offset: usize) usize {
        return if (line == 0)
            byte_offset
        else
            byte_offset - self.line_ends[line - 1] - 1;
    }

    pub fn getLine(self: Self, line: usize) []const u8 {
        // Given this should only ever be called for a small handful of lines
        // we trim the potential carriage return in here and not during parsing
        // to keep parsing as simple as possible.
        return std.mem.trimEnd(u8, if (line == 0)
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
        writer: *std.Io.Writer,
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
        writer: *std.Io.Writer,
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
        const data = "123456789" ++ newline ++ "abcdefghi" ++ newline;
        var input = std.Io.Reader.fixed(data);

        var renderer = try LintFileRenderer.init(
            std.testing.allocator,
            &input,
        );
        defer renderer.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(.{ 0, 0 }, renderer.lineAndColumn(0)); // 1
        try std.testing.expectEqualDeep(.{ 0, 1 }, renderer.lineAndColumn(1)); // 2
        // ...
        try std.testing.expectEqualDeep(.{ 0, 8 }, renderer.lineAndColumn(8)); // 9
        // newline
        std.debug.assert(data[8 + newline.len + 1] == 'a');
        try std.testing.expectEqualDeep(.{ 1, 0 }, renderer.lineAndColumn(8 + newline.len + 1)); // a
        try std.testing.expectEqualDeep(.{ 1, 1 }, renderer.lineAndColumn(8 + newline.len + 2)); // b
        // ...
        try std.testing.expectEqualDeep(.{ 1, 8 }, renderer.lineAndColumn(8 + newline.len + 9)); // i

        try std.testing.expectEqualStrings("123456789", renderer.getLine(0));
        try std.testing.expectEqualStrings("abcdefghi", renderer.getLine(1));
        try std.testing.expectEqualStrings("", renderer.getLine(2));

        {
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();

            try renderer.render(
                1,
                3,
                1,
                5,
                &output.writer,
                .no_color,
            );

            try std.testing.expectEqualStrings(
                \\ 2 | abcdefghi
                \\   |    ^^^
            , output.written());
        }

        {
            var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer output.deinit();

            try renderer.render(
                0,
                3,
                1,
                1,
                &output.writer,
                .no_color,
            );

            try std.testing.expectEqualStrings(
                \\ 1 | 123456789
                \\   |    ^^^^^^
                \\ 2 | abcdefghi
                \\   | ^^
            , output.written());
        }
    }
}

var printer_singleton: Printer = .empty;
/// Singleton printer for use for the lifetime of the process
pub var process_printer = &printer_singleton;

pub const Printer = struct {
    verbose: bool,
    stdout: ?*std.Io.Writer = null,
    stderr: ?*std.Io.Writer = null,
    tty: ansi.Tty,

    const empty: Printer = .{ .verbose = false, .tty = .no_color };

    pub fn init(self: *Printer, stdout: *std.Io.Writer, stderr: *std.Io.Writer, tty: ansi.Tty, verbose: bool) void {
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
        var writer: *std.Io.Writer = switch (kind) {
            .verbose => if (self.verbose)
                self.stdout orelse @panic("Requires initAuto or set stdout")
            else
                return,
            .err => self.stderr orelse @panic("Requires initAuto or set stderr"),
            .out => self.stdout orelse @panic("Requires initAuto or set stdout"),
        };

        return writer.print(fmt, args) catch |e| {
            std.log.err("Failed to write to std(err|out): {s}", .{@errorName(e)});
            std.log.err("\tOutput: " ++ fmt, args);
        };
    }

    pub fn flush(self: *Printer) !void {
        try self.stderr.?.flush();
        try self.stdout.?.flush();
    }
};

const ansi = @import("ansi.zig");
const std = @import("std");
const max_zig_file_size_bytes = @import("session.zig").max_zig_file_size_bytes;
const shims = @import("shims.zig");
