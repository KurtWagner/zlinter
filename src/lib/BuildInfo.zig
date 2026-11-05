//! Serialized object passed to linter execution when using CLI arguments is
//! not technically feasible (or if we want to avoid exposing "internal"
//! APIs to the CLI of zlinter).

const BuildInfo = @This();

/// Similar to `Args.include_paths` but is populated by the build runner and
/// piped into the zlinter execution.
include_paths: ?[]const []const u8 = null,

/// Similar to `Args.exclude_paths` but is populated by the build runner and
/// piped into the zlinter execution.
exclude_paths: ?[]const []const u8 = null,

pub const default: BuildInfo = .{};

pub fn deinit(self: BuildInfo, gpa: std.mem.Allocator) void {
    if (self.exclude_paths) |paths| {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    if (self.include_paths) |paths| {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }
}

pub fn consumeStdinAlloc(
    stdin_reader: anytype,
    gpa: std.mem.Allocator,
    printer: *rendering.Printer,
) error{ OutOfMemory, InvalidArgs }!?BuildInfo {
    const size = stdin_reader.readInt(usize, .little) catch |e| {
        if (e == error.EndOfStream) return null else {
            printer.println(.err, "Failed to read stdin length: {s}", .{@errorName(e)});
            return error.InvalidArgs;
        }
    };
    var buffer = try gpa.alloc(u8, size + 1);
    @memset(buffer, 0);
    defer gpa.free(buffer);

    stdin_reader.readNoEof(buffer[0..size]) catch |e| {
        printer.println(.err, "Failed to read stdin content: {s}", .{@errorName(e)});
        return error.InvalidArgs;
    };

    return zon.parseFromSlice(BuildInfo, gpa, buffer[0..size :0], null) catch |e| {
        switch (e) {
            error.ParseZon => {
                printer.println(.err, "Failed to parse stdin zon content: {s}", .{@errorName(e)});
                return error.InvalidArgs;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    };
}

const rendering = @import("rendering.zig");
const std = @import("std");
const zon = @import("zon.zig");

test "default" {
    try std.testing.expect(BuildInfo.default.include_paths == null);
    try std.testing.expect(BuildInfo.default.exclude_paths == null);
}

test "deinit default" {
    var info = BuildInfo.default;
    info.deinit(std.testing.allocator); // should not crash
}

test "deinit with paths" {
    const gpa = std.testing.allocator;
    var include_paths = try gpa.alloc([]const u8, 1);
    include_paths[0] = try gpa.dupe(u8, "src");
    var exclude_paths = try gpa.alloc([]const u8, 1);
    exclude_paths[0] = try gpa.dupe(u8, "vendor");
    var info = BuildInfo{
        .include_paths = include_paths,
        .exclude_paths = exclude_paths,
    };
    info.deinit(gpa); // should free without leak (testing.allocator detects leaks)
}

test "consumeStdinAlloc empty stdin" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const result = try BuildInfo.consumeStdinAlloc(
        stdin_fbs.reader(),
        std.testing.allocator,
        rendering.process_printer,
    );
    try std.testing.expect(result == null);
}

test "consumeStdinAlloc invalid zon" {
    var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    const invalid_zon = "not valid zon";
    var buf: [@sizeOf(usize) + invalid_zon.len]u8 = undefined;
    std.mem.writeInt(usize, buf[0..@sizeOf(usize)], invalid_zon.len, .little);
    @memcpy(buf[@sizeOf(usize)..], invalid_zon);
    var stdin_fbs = std.io.fixedBufferStream(&buf);
    try std.testing.expectError(
        error.InvalidArgs,
        BuildInfo.consumeStdinAlloc(
            stdin_fbs.reader(),
            std.testing.allocator,
            rendering.process_printer,
        ),
    );
}
