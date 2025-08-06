fn main() void {
    std.debug.print("ok");

    var ok = std.ArrayList(u8).init(allocator);
}

fn has_eror() !void {
    std.debug.print("ok");

    var ok = std.ArrayList(u8).init(allocator);
}

const std = @import("std");
