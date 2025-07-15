//! Regression test for https://github.com/KurtWagner/zlinter/issues/59

pub fn main() void {
    const Tag = enum { a, b, c };

    // The following line should not be picked up as the struct looks like a tuple
    // so the field name is not exactly present and thus can't be checked
    const Tuple = struct { u32, Tag, []const u8 };

    const tuple = Tuple{ 10, .a, "hello" };
    std.debug.print("{any}", .{tuple});
}

const std = @import("std");
