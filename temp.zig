const std = @import("std");
const banana = @import("banana");
const apple = @import("apple.zig");

const namespace = struct {
    const another_banana = @import("banana");
    const another_apple = @import(
        "apple.zig",
    );
};

fn main() void {
    const inner = @import("inner.zig");
    const also_inner = @import("also_inner.zig");
}

const bottom = @import("bottom.zig");
