//! Serialized object passed to linter execution when using CLI arguments is
//! not technically feasible (or if we want to avoid exposing "internal"
//! APIs to the CLI of zlinter).

const BuildInfo = @This();

pub const CompileUnitSelector = union(enum) {
    exe,
    lib,
    obj,
    @"test",
    all,
    name: []const u8,
};

/// Similar to `Args.include_paths` but is populated by the build runner and
/// piped into the zlinter execution.
include_paths: ?[]const []const u8 = null,

/// Similar to `Args.exclude_paths` but is populated by the build runner and
/// piped into the zlinter execution.
exclude_paths: ?[]const []const u8 = null,

/// Compile unit selectors whose module/import contexts should be used while
/// linting. If null, zlinter defaults to executables if present, otherwise
/// libraries, otherwise objects, otherwise tests.
compile_units: ?[]const CompileUnitSelector = null,

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

    if (self.compile_units) |selectors| {
        for (selectors) |selector| {
            switch (selector) {
                .name => |name| gpa.free(name),
                .exe, .lib, .obj, .@"test", .all => {},
            }
        }
        gpa.free(selectors);
    }
}

pub fn consumeStdinAlloc(
    stdin_reader: *std.Io.Reader,
    gpa: std.mem.Allocator,
    printer: *rendering.Printer,
) error{ OutOfMemory, InvalidArgs }!?BuildInfo {
    const size = stdin_reader.takeInt(u32, .little) catch |e| {
        if (e == error.EndOfStream) return null else {
            printer.println(.err, "Failed to read stdin length: {s}", .{@errorName(e)});
            return error.InvalidArgs;
        }
    };
    var buffer = try gpa.alloc(u8, size + 1);
    @memset(buffer, 0);
    defer gpa.free(buffer);

    stdin_reader.readSliceAll(buffer[0..size]) catch |e| {
        printer.println(.err, "Failed to read stdin content: {s}", .{@errorName(e)});
        return error.InvalidArgs;
    };

    return std.zon.parse.fromSliceAlloc(BuildInfo, gpa, buffer[0..size :0], null, .{
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

test {
    std.testing.refAllDecls(@This());
}
