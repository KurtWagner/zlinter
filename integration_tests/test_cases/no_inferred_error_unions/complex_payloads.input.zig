const std = @import("std");
const Thing = struct {};

pub fn bytes() ![]const u8 {
    return error.Always;
}

pub fn maybePtr() !?*Thing {
    return error.Always;
}

pub fn ptr() !*Thing {
    return error.Always;
}

pub fn array() ![4]u8 {
    return error.Always;
}

pub fn namespaced() !std.ArrayList(u8) {
    return error.Always;
}
