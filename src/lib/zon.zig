pub const Diagnostics = switch (version.zig) {
    .@"0.14" => std.zon.parse.Status,
    .@"0.15" => std.zon.parse.Diagnostics,
};

pub fn parseFileAlloc(
    T: type,
    dir: std.fs.Dir,
    cwd_file_path: []const u8,
    diagnostics: ?*Diagnostics,
    gpa: std.mem.Allocator,
) !T {
    const file = try dir.openFile(cwd_file_path, .{
        .mode = .read_only,
    });
    defer file.close();

    const null_terminated = value: {
        const file_content = switch (version.zig) {
            .@"0.14" => try file.reader().readAllAlloc(gpa, session.max_zig_file_size_bytes),
            .@"0.15" => try file.deprecatedReader().readAllAlloc(gpa, session.max_zig_file_size_bytes),
        };
        defer gpa.free(file_content);
        break :value try gpa.dupeZ(u8, file_content);
    };
    defer gpa.free(null_terminated);

    return try std.zon.parse.fromSlice(
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

const version = @import("version.zig");
const testing = @import("testing.zig");
const session = @import("session.zig");
const std = @import("std");
