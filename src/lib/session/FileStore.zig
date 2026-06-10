const FileStore = @This();

pub const FileId = enum(u32) {
    _,
};

pub const File = struct {
    /// AST of file.
    tree: std.zig.Ast,

    /// Source of file contents.
    source: [:0]const u8,

    /// Absolute path to file.
    abs_path: []const u8,
};

/// Use `fileTree(...)`, `fileSource(...)` and `fileAbsPath(...)` to
/// access the underlying data associated with a file resolved using
/// `resolve(...)`.
files: std.MultiArrayList(File),

/// Normalized absolute path strings to file id. Don't access this
/// directly, instead use `resolve(...)` and use the returned index with
/// `ast(index)` and `source(index)`.
path_to_index: std.StringHashMapUnmanaged(FileId),

pub const empty: FileStore = .{
    .files = .empty,
    .path_to_index = .empty,
};

pub fn deinit(fs: *FileStore, gpa: std.mem.Allocator) void {
    var slice = fs.files.slice();
    for (
        slice.items(.abs_path),
        slice.items(.source),
        slice.items(.tree),
    ) |abs_path, source, *tree| {
        gpa.free(abs_path);
        gpa.free(source);
        tree.deinit(gpa);
    }

    fs.files.deinit(gpa);
    fs.path_to_index.deinit(gpa); // Paths owned by File.
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

    const abs_path = try gpa.dupe(u8, normal_path);
    errdefer gpa.free(abs_path);

    const id: FileId = @enumFromInt(@as(u32, @intCast(fs.files.len)));

    try fs.files.append(gpa, .{
        .tree = tree,
        .abs_path = abs_path,
        .source = source,
    });
    errdefer _ = fs.files.swapRemove(@intFromEnum(id));

    try fs.path_to_index.putNoClobber(gpa, abs_path, id);
    errdefer _ = fs.path_to_index.remove(abs_path);

    std.debug.print("File store: adding '{s}\n", .{abs_path});

    return id;
}

pub fn fileTree(fs: *const FileStore, id: FileId) *const std.zig.Ast {
    const index = @intFromEnum(id);
    std.debug.assert(index < fs.files.len);
    return &fs.files.items(.tree)[index];
}

pub fn fileSource(fs: *const FileStore, id: FileId) []const u8 {
    const index = @intFromEnum(id);
    std.debug.assert(index < fs.files.len);
    return fs.files.items(.source)[index];
}

pub fn fileAbsPath(fs: *const FileStore, id: FileId) []const u8 {
    const index = @intFromEnum(id);
    std.debug.assert(index < fs.files.len);
    return fs.files.items(.abs_path)[index];
}

const std = @import("std");
const tracy = @import("tracy");
