var questionable: ?[123]u8 = undefined;

fn main() void {
    const message = questionable orelse undefined;
    std.fmt.log("{s}", .{ undefined, message });
}

const MyStruct = struct {
    name: []const u8,

    pub fn deinit(self: *MyStruct) void {
        self.* = undefined;
    }
};

const std = @import("std");

// We expect any undefined with a test to simply be ignored as really we expect
// the test to fail if there's issues
test {
    var this_is_a_test_so_who_cares: u32 = undefined;

    const Struct = struct {
        var nested_who_cares: f32 = undefined;
    };

    this_is_a_test_so_who_cares = 0;
    _ = Struct{};
}

// These should all be ok as they equal or end with the default excluded
// names "mem", "buffer", etc.
var buffer: []u8 = undefined;
var some_buff: []u8 = undefined;
var some_buf: []u8 = undefined;
var mem: []u8 = undefined;
var my_mem: []u8 = undefined;
var my_memory: []u8 = undefined;

// These will be caught as they're const, even with the name
const bad_memory: []u8 = undefined;
const bad_buffer: []u8 = undefined;
