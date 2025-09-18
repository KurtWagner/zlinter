pub fn sample() ![]const u8 {
    var ok = std.ArrayList(u8).empty;

    return ok.toOwnedSlice();
}

pub fn ya(allocator: std.mem.Allocator) !void {
    const deinit_wip = true;
    var wip = try std.ArrayList(u8).initCapacity(allocator, 10);
    defer if (deinit_wip) wip.deinit();
}

pub fn main() !void {
    var debug_gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_gpa_state.deinit();
}

pub fn mainA() !void {
    var debug_gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer {
        if (debug_gpa_state.deinit() == .leak) {}
    }
}

const std = @import("std");
