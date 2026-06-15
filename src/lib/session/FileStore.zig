const FileStore = @This();

pub const max_zig_file_size_bytes = bytes: {
    const bytes_in_mb = 1024 * 1024;
    break :bytes 32 * bytes_in_mb;
};

pub const FileId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) FileId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: FileId) usize {
        return @intFromEnum(self);
    }
};

pub const File = struct {
    /// AST of file.
    tree: std.zig.Ast,

    /// Owned source of file contents
    source: [:0]const u8,

    /// Owned absolute path to file
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

pub fn deinit(self: *FileStore, gpa: std.mem.Allocator) void {
    var slice = self.files.slice();
    for (
        slice.items(.abs_path),
        slice.items(.source),
        slice.items(.tree),
    ) |abs_path, source, *tree| {
        gpa.free(abs_path);
        gpa.free(source);
        tree.deinit(gpa);
    }

    self.files.deinit(gpa);
    self.path_to_index.deinit(gpa); // Paths owned by File.
}

pub fn resolve(
    self: *FileStore,
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
    if (self.path_to_index.get(normal_path)) |index| return index;

    const source: [:0]const u8 = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        normal_path,
        gpa,
        .limited(max_zig_file_size_bytes),
        .of(u8),
        0,
    );
    errdefer gpa.free(source);

    var tree = try std.zig.Ast.parse(gpa, source, .zig);
    errdefer tree.deinit(gpa);

    const abs_path = try gpa.dupe(u8, normal_path);
    errdefer gpa.free(abs_path);

    const id: FileId = .fromIndex(self.files.len);

    try self.files.append(gpa, .{
        .tree = tree,
        .abs_path = abs_path,
        .source = source,
    });
    errdefer _ = self.files.swapRemove(id.toIndex());

    try self.path_to_index.putNoClobber(gpa, abs_path, id);
    errdefer _ = self.path_to_index.remove(abs_path);

    std.debug.print("File store: adding '{s}\n", .{abs_path});

    return id;
}

pub fn fileTree(self: *const FileStore, id: FileId) *const std.zig.Ast {
    return &self.files.items(.tree)[id.toIndex()];
}

pub fn fileSource(self: *const FileStore, id: FileId) [:0]const u8 {
    return self.files.items(.source)[id.toIndex()];
}

pub fn fileAbsPath(self: *const FileStore, id: FileId) []const u8 {
    return self.files.items(.abs_path)[id.toIndex()];
}

pub fn resolvedFile(self: *const FileStore, abs_path: []const u8) ?FileId {
    return self.path_to_index.get(abs_path);
}

const std = @import("std");
const tracy = @import("tracy");
