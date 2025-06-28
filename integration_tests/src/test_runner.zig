pub fn main() !void {
    var mem: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const out = std.io.getStdOut().writer();

    for (builtin.test_functions) |t| {
        t.func() catch |err| {
            try std.fmt.format(out, "Integration test for '{s}'' failed: {}\n", .{ args[1], err });
            continue;
        };
        try std.fmt.format(out, "Integration test for '{s}'' passed\n", .{args[1]});
    }
}

const std = @import("std");
const builtin = @import("builtin");
