pub fn sample() ![]const u8 {
    var ok = std.ArrayList(u8).empty;

    return ok.toOwnedSlice();
}

const std = @import("std");
