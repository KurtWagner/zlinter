fn GoodList(T: type) type {
    _ = T;
    return struct {};
}

fn BadList(comptime T: type) type {
    _ = T;
    return struct {};
}

fn good(comptime n: usize) void {
    _ = n;
}

fn bad(comptime a: comptime_int) comptime_int {
    return a;
}

fn alsobad(comptime x: comptime_float) comptime_float {
    return x;
}

fn fine(comptime allocator: std.mem.Allocator) void {
    _ = allocator;
}

fn mixed(comptime T: type, n: usize, comptime F: comptime_float) void {
    _ = T;
    _ = n;
    _ = F;
}

const std = @import("std");
