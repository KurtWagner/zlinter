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

const std = @import("std");
