const ansi_red_bold = "\x1B[31;1m";
const ansi_green_bold = "\x1B[32;1m";
const ansi_reset = "\x1B[0m";

pub fn main() !void {
    var mem: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const out = std.io.getStdOut().writer();

    for (builtin.test_functions) |t| {
        t.func() catch |err| {
            try std.fmt.format(out, "Integration test '{s}' {s}failed{s}: {}\n", .{ args[1], ansi_red_bold, ansi_reset, err });
            continue;
        };
        try std.fmt.format(out, "Integration test '{s}' {s}passed{s}\n", .{ args[1], ansi_green_bold, ansi_reset });
    }
}

const std = @import("std");
const builtin = @import("builtin");
