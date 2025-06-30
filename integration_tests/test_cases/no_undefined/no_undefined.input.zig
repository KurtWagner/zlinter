var questionable: ?[123]u8 = undefined;

fn main() void {
    const message = questionable orelse undefined;
    std.fmt.log("{s}", .{ undefined, message });
}

const std = @import("std");
