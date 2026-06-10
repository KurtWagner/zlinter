const FileStore = @This();

pub const FileId = enum(u32) {
    _,
};

/// Access using `ast(index)`.
asts: std.ArrayList(std.zig.Ast),

/// Access using `source(index)`.
sources: std.ArrayList([:0]const u8),

/// Access using `path(index)` (memory of string owned by `path_to_index`).
paths: std.ArrayList([]const u8),

/// Normalized absolute path strings to file id. Don't access this
/// directly, instead use `resolve(...)` and use the returned index with
/// `ast(index)` and `source(index)`.
path_to_index: std.StringHashMapUnmanaged(FileId),

pub const empty: FileStore = .{
    .asts = .empty,
    .sources = .empty,
    .paths = .empty,
    .path_to_index = .empty,
};

pub fn deinit(fs: *FileStore, gpa: std.mem.Allocator) void {
    for (fs.asts.items) |*tree|
        tree.deinit(gpa);

    for (fs.sources.items) |source|
        gpa.free(source);

    var path_it = fs.path_to_index.keyIterator();
    while (path_it.next()) |path|
        gpa.free(path.*);

    fs.asts.deinit(gpa);
    fs.sources.deinit(gpa);
    fs.path_to_index.deinit(gpa);
    fs.paths.deinit(gpa); // Strings owned by `path_to_index`
}

pub fn resolve(
    fs: *FileStore,
    input_path: []const u8,
    io: std.Io,
    gpa: std.mem.Allocator,
    cwd: []const u8,
) !FileId {
    const zone = tracy.traceNamed(@src(), "FileStore.resolve");
    defer zone.end();

    std.log.info("Resolving '{s}' to '{s}'", .{ cwd, input_path });

    var fba_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = std.fs.path.resolve(
        fba.allocator(),
        &.{ cwd, input_path },
    ) catch unreachable;
    if (fs.path_to_index.get(normal_path)) |index| return index;

    std.debug.assert(fs.asts.items.len == fs.sources.items.len);

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        normal_path,
        gpa,
        .limited(std.math.maxInt(u32)),
        .@"1",
        0,
    );
    errdefer gpa.free(source);

    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    errdefer tree.deinit(gpa);

    const path_key = try gpa.dupe(u8, normal_path);
    errdefer gpa.free(path_key);

    const id: FileId = @enumFromInt(@as(u32, @intCast(fs.asts.items.len)));
    try fs.asts.append(gpa, tree);
    errdefer _ = fs.asts.swapRemove(@intFromEnum(id));

    try fs.sources.append(gpa, source);
    errdefer _ = fs.sources.swapRemove(@intFromEnum(id));

    try fs.paths.append(gpa, path_key);
    errdefer _ = fs.paths.swapRemove(@intFromEnum(id));

    try fs.path_to_index.putNoClobber(gpa, path_key, id);
    errdefer _ = fs.path_to_index.remove(path_key);

    std.debug.print("File store: adding '{s}\n", .{path_key});

    return id;
}

pub fn fileAst(fs: *const FileStore, id: FileId) *const std.zig.Ast {
    const index = @intFromEnum(id);
    std.debug.assert(index < fs.asts.items.len);
    return &fs.asts.items[index];
}

pub fn fileSource(fs: *const FileStore, id: FileId) []const u8 {
    const index = @intFromEnum(id);
    std.debug.assert(index < fs.asts.items.len);
    return fs.sources.items[index];
}

pub fn filePath(fs: *const FileStore, id: FileId) []const u8 {
    const index = @intFromEnum(id);
    std.debug.assert(index < fs.asts.items.len);
    return fs.paths.items[index];
}

const std = @import("std");
const tracy = @import("tracy");
