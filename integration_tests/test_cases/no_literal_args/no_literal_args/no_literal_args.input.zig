pub fn main() void {
    // Not ok:
    method(1, 0.5, false, 'a', "Jack");

    // Ok:
    const age = 10;
    const height = 0.5;
    const is_alive = false;
    const initial: u8 = 'a';
    const name: []const u8 = "Jack";
    method(age, height, is_alive, initial, name);

    // Ok: build.zig has configured to exclude fn names excludeFnName
    excludeFnName(1, 0.5, false, 'a', "Jack");
}

// Ok: as within test and configured to exclude tests
test {
    method(1, 0.5, false, 'a', "Jack");
}

fn method(age: u32, height: f32, is_alive: bool, initial: u8, name: []const u8) void {
    std.debug.print("{d} {d} {} {c} {s}", .{ age, height, is_alive, initial, name });
}

fn excludeFnName(age: u32, height: f32, is_alive: bool, initial: u8, name: []const u8) void {
    std.debug.print("{d} {d} {} {c} {s}", .{ age, height, is_alive, initial, name });
}

const std = @import("std");
