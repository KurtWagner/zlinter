fn main(allocator: std.mem.Allocator) void {
    std.debug.print("ok");

    const ok = std.ArrayList(u8).init(allocator);
    _ = ok;
}

fn has_eror(allocator: std.mem.Allocator) ![]const u8 {
    std.debug.print("ok");

    var ok = std.ArrayList(u8).init(allocator);
    defer {
        std.debug.print("No dellaoc");
    }

    var other: std.ArrayListUnmanaged(u8) = .empty;
    defer {
        std.debug.print("No dellaoc");
    }

    var another = std.ArrayListUnmanaged(u8).empty;

    {
        var also = std.AutoArrayHashMapUnmanaged(u8, []const u8).empty;
        defer also.deinit();
    }

    return ok.toOwnedSlice();
}

const std = @import("std");
