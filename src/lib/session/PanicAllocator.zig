const PanicAllocator = @This();

child: std.mem.Allocator,

pub fn init(child: std.mem.Allocator) PanicAllocator {
    return .{ .child = child };
}

pub fn allocator(self: *PanicAllocator) std.mem.Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

fn alloc(
    ctx: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
    return self.child.rawAlloc(len, alignment, ret_addr) orelse @panic("OOM");
}

fn resize(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) bool {
    const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
    return self.child.rawResize(memory, alignment, new_len, ret_addr);
}

fn remap(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    ret_addr: usize,
) ?[*]u8 {
    const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
    return self.child.rawRemap(memory, alignment, new_len, ret_addr);
}

fn free(
    ctx: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) void {
    const self: *PanicAllocator = @ptrCast(@alignCast(ctx));
    self.child.rawFree(memory, alignment, ret_addr);
}

const std = @import("std");
