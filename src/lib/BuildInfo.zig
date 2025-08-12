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

    return std.zon.parse.fromSlice(BuildInfo, gpa, buffer[0..size :0], null, .{
        .ignore_unknown_fields = false,
        .free_on_error = true,
    }) catch |e| {
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
