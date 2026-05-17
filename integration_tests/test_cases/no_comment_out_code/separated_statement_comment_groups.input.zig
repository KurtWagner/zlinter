pub fn main() void {
    // Deliberate non-code comment.

    const x: u32 = 2;
    _ = x;

    // std.debug.print("{d}", .{1});

    // if (x > 0) {
    //     std.debug.print("{d}", .{x});
    // }
}

const std = @import("std");
