// Within functions:
fn hasHiddenAllocations() !void {
    const bad_a = try std.heap.c_allocator.create(u32);
    defer std.heap.c_allocator.destroy(bad_a);

    const bad_b = try heap.page_allocator.alloc(u8, 2);
    defer heap.page_allocator.free(bad_b);

    // TODO: These should also be picked up.
    var debug_allocator = DebugAllocator.init();
    const bad_c = try debug_allocator.create(u32);
    defer debug_allocator.destroy(bad_c);
}

fn doesNotHaveHiddenAllocatons(allocator: std.mem.Allocator) !void {
    const bad_a = try allocator.create(u32);
    defer allocator.destroy(bad_a);

    const bad_b = try allocator.alloc(u8, 2);
    defer allocator.free(bad_b);
}

const DebugAllocator = heap.DebugAllocator(.{});
const heap = std.heap;
const std = @import("std");
