// TODO: Move this to rendering.zig

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
                self.stdout orelse .{ .context = .{ .file = std.io.getStdOut() } }
            else
                return,
            .err => self.stderr orelse .{ .context = .{ .file = std.io.getStdErr() } },
            .out => self.stdout orelse .{ .context = .{ .file = std.io.getStdOut() } },
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

// TODO: Look into the following bug?
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
