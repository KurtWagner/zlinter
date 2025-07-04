const OutputWriter = @This();

verbose: bool,

pub const Kind = enum {
    out,
    verbose,
    err,
};

pub fn init() @This() {
    return .{ .verbose = false };
}

pub inline fn println(self: OutputWriter, kind: Kind, comptime fmt: []const u8, args: anytype) void {
    return self.print(kind, fmt ++ "\n", args);
}

pub fn print(self: OutputWriter, kind: Kind, comptime fmt: []const u8, args: anytype) void {
    var writer = switch (kind) {
        .verbose => if (self.verbose)
            std.io.getStdOut().writer()
        else
            return,
        .err => std.io.getStdErr().writer(),
        .out => std.io.getStdOut().writer(),
    };

    return writer.print(fmt, args) catch |e| {
        std.log.err("Failed to write to std(err|out): {s}", .{@errorName(e)});
        std.log.err("\tOutput: " ++ fmt, args);
    };
}

const std = @import("std");
