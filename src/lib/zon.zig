pub const Diagnostics = std.zon.parse.Diagnostics;

pub fn parseFileAlloc(
    T: type,
    dir: std.Io.Dir,
    cwd_file_path: []const u8,
    diagnostics: ?*Diagnostics,
    io: std.Io,
    gpa: std.mem.Allocator,
) !T {
    const file = try dir.openFile(io, cwd_file_path, .{
        .mode = .read_only,
    });
    defer file.close(io);

    const null_terminated = null_terminated: {
        var file_reader_buffer: [1024]u8 = undefined;
        var file_reader = file.reader(io, &file_reader_buffer);

        var buffer: std.ArrayList(u8) = .empty;
        defer buffer.deinit(gpa);

        if (file_reader.getSize()) |size| {
            const casted_size = std.math.cast(u32, size) orelse return error.StreamTooLong;
            try buffer.ensureTotalCapacityPrecise(gpa, casted_size + 1); // +1 for null term
        } else |_| {
            // Do nothing.
        }

        try file_reader.interface.appendRemaining(
            gpa,
            &buffer,
            .limited(session.max_zig_file_size_bytes),
        );

        break :null_terminated try buffer.toOwnedSliceSentinel(gpa, 0);
    };
    defer gpa.free(null_terminated);

    return try std.zon.parse.fromSliceAlloc(
        T,
        gpa,
        null_terminated,
        diagnostics,
        .{
            .ignore_unknown_fields = false,
            .free_on_error = true,
        },
    );
}

test "parseFileAlloc" {
    const BasicStruct = struct {
        age: u32 = 10,
        names: []const []const u8 = &.{ "a", "b" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try testing.writeFile(
        tmp_dir.dir,
        "a.zon",
        \\.{}
        ,
    );
    try std.testing.expectEqualDeep(
        BasicStruct{},
        try parseFileAlloc(
            BasicStruct,
            tmp_dir.dir,
            "a.zon",
            null,
            std.testing.io,
            arena.allocator(),
        ),
    );

    try testing.writeFile(
        tmp_dir.dir,
        "b.zon",
        \\.{
        \\ .age = 20,
        \\ .names = .{"c", "d"},
        \\}
        ,
    );
    try std.testing.expectEqualDeep(
        BasicStruct{
            .age = 20,
            .names = &.{ "c", "d" },
        },
        try parseFileAlloc(
            BasicStruct,
            tmp_dir.dir,
            "b.zon",
            null,
            std.testing.io,
            arena.allocator(),
        ),
    );

    var diagnostics = Diagnostics{};
    try testing.writeFile(
        tmp_dir.dir,
        "b.zon",
        \\.{ .not_found = 10 }
        ,
    );
    const actual = parseFileAlloc(
        BasicStruct,
        tmp_dir.dir,
        "b.zon",
        &diagnostics,
        std.testing.io,
        arena.allocator(),
    );
    try std.testing.expectError(
        error.ParseZon,
        actual,
    );
    var it = diagnostics.iterateErrors();
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}

const session = @import("session.zig");
const std = @import("std");
const testing = @import("testing.zig");
