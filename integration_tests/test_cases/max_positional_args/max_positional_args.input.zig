pub fn good() void {}

pub fn alsoGood(a: u32, b: u32, c: u32, d: u32, e: u32) void {
    std.debug.print("{d} {d} {d} {d} {d}", .{ a, b, c, d, e });
}

pub fn notGood(a: u32, b: u32, c: u32, d: u32, e: u32, f: u32) void {
    std.debug.print("{d} {d} {d} {d} {d} {d}", .{ a, b, c, d, e, f });
}

const std = @import("std");
