// Anything in here is ok as the function does not return an error
pub fn noError() void {
    var good_a = std.ArrayList(u8).init(std.heap.page_allocator);
    var good_b: std.ArrayList(u8) = .init(std.heap.page_allocator);
    var good_c: std.AutoHashMapUnmanaged(u8, void) = .empty;
    var good_d = std.AutoHashMapUnmanaged(u8, void).empty;

    good_a.deinit();
    good_b.deinit();
    good_c.deinit(std.heap.page_allocator);
    good_d.deinit(std.heap.page_allocator);
}

pub fn hasErrorButWithDefers(input: u32) error{NotOk}!void {
    var has_cleanup_a = std.ArrayList(u8).init(std.heap.page_allocator);
    var has_cleanup_b: std.ArrayList(u8) = .init(std.heap.page_allocator);
    var has_cleanup_c: std.AutoHashMapUnmanaged(u8, void) = .empty;
    var has_cleanup_d = std.AutoHashMapUnmanaged(u8, void).empty;

    defer has_cleanup_a.deinit();
    defer {
        has_cleanup_b.deinit();
        has_cleanup_c.deinit(std.heap.page_allocator);
    }
    errdefer has_cleanup_d.deinit(std.heap.page_allocator);

    if (input == 0) return error.NotOk;

    has_cleanup_a.deinit();
    has_cleanup_b.deinit();
    has_cleanup_c.deinit(std.heap.page_allocator);
    has_cleanup_d.deinit(std.heap.page_allocator);
}

pub fn hasError(input: u32) error{NotOk}!void {
    var bad_a = std.ArrayList(u8).init(std.heap.page_allocator);
    var bad_b: std.ArrayList(u8) = .init(std.heap.page_allocator);
    var bad_c: std.AutoHashMapUnmanaged(u8, void) = .empty;
    var bad_d = std.AutoHashMapUnmanaged(u8, void).empty;

    if (input == 0) return error.NotOk;

    bad_a.deinit();
    bad_b.deinit();
    bad_c.deinit(std.heap.page_allocator);
    bad_d.deinit(std.heap.page_allocator);
}

const MyArray = std.ArrayList(u8);
const MyArrayUmanaged = std.ArrayListUnmanaged(u8);
const MyBufSet = std.BufSet;

pub fn hasErrorReferencedStdArray(input: u32) error{NotOk}!void {
    var bad_a = MyArray.init(std.heap.page_allocator);
    var bad_b: MyArray = .init(std.heap.page_allocator);
    var bad_c: MyArrayUmanaged = .empty;
    var bad_d = MyArrayUmanaged.empty;

    const ambiguous_name = std.heap.c_allocator;
    var bad_e: MyBufSet = .init(ambiguous_name);
    var bad_f = MyBufSet.init(ambiguous_name);

    if (input == 0) return error.NotOk;

    bad_a.deinit();
    bad_b.deinit();
    bad_c.deinit(std.heap.page_allocator);
    bad_d.deinit(std.heap.page_allocator);
    bad_e.deinit();
    bad_f.deinit();
}

pub fn hasErrorButWithArena(input: u32) error{NotOk}!void {
    const arena_allocator = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var buffer: [1024]u8 = undefined;
    const fba = std.heap.FixedBufferAllocator.init(&buffer);
    const fixed_buffer_allocator = fba.allocator();

    var has_arena_a = std.ArrayList(u8).init(fba.allocator());
    var has_arena_b: std.ArrayList(u8) = .init(arena_allocator.allocator());
    var has_arena_c: std.ArrayList(u8) = .init(arena);
    var has_arena_d = std.ArrayLive(u32).init(fixed_buffer_allocator);

    if (input == 0) return error.NotOk;

    has_arena_a.deinit();
    has_arena_b.deinit();
    has_arena_c.deinit(std.heap.page_allocator);
    has_arena_d.deinit(std.heap.page_allocator);
}

const std = @import("std");
