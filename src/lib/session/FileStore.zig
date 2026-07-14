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

    /// Owned zero-indexed byte offsets for the start of each source line.
    line_starts: []const usize,

    /// Owned absolute path to file
    abs_path: []const u8,
};

pub const FilePosition = struct {
    /// Zero-indexed line number.
    line: usize,
    /// Zero-indexed byte column within the line.
    column: usize,
};

pub const FileRange = struct {
    start: FilePosition,
    end: FilePosition,
};

/// Use `fileTree(...)`, `fileSource(...)` and `fileAbsPath(...)` to
/// access the underlying data associated with a file resolved using
/// `resolve(...)`.
files: std.MultiArrayList(File) = .empty,

/// Normalized absolute path strings to file id. Don't access this
/// directly, instead use `resolve(...)` and use the returned index with
/// `ast(index)` and `source(index)`.
file_id_by_path: std.StringHashMapUnmanaged(FileId) = .empty,

runtime: *const LintRuntime,

pub fn init(runtime: *const LintRuntime) FileStore {
    return .{
        .runtime = runtime,
    };
}

pub fn resolve(
    self: *FileStore,
    input_path: []const u8,
) error{ResolutionError}!FileId {
    return self.resolveFrom(input_path, self.runtime.cwd);
}

pub fn resolveStdlib(
    self: *FileStore,
) error{ResolutionError}!FileId {
    return self.resolveFrom("std/std.zig", self.runtime.zig_lib_directory);
}

pub fn resolveFrom(
    self: *FileStore,
    input_path: []const u8,
    cwd: []const u8,
) error{ResolutionError}!FileId {
    const zone = tracy.traceNamed(@src(), "FileStore.resolveFrom");
    defer zone.end();

    const io = self.runtime.io;
    const session_arena = self.runtime.sessionArena();

    var fba_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = oom(std.Io.Dir.path.resolve(
        fba.allocator(),
        &.{ cwd, input_path },
    ));
    if (self.file_id_by_path.get(normal_path)) |index| return index;

    const source: [:0]const u8 = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        normal_path,
        session_arena,
        .limited(max_zig_file_size_bytes),
        .of(u8),
        0,
    ) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM"),
        else => {
            std.log.err("Could not read file '{s}' due to {t}", .{ normal_path, e });
            return error.ResolutionError;
        },
    };

    const tree = oom(std.zig.Ast.parse(session_arena, source, .{ .mode = .zig }));
    const line_starts = oom(allocLineStarts(session_arena, source));
    const abs_path = oom(session_arena.dupe(u8, normal_path));
    const id: FileId = .fromIndex(self.files.len);

    oom(self.files.append(session_arena, .{
        .tree = tree,
        .abs_path = abs_path,
        .source = source,
        .line_starts = line_starts,
    }));

    oom(self.file_id_by_path.putNoClobber(session_arena, abs_path, id));

    std.log.info("Resolving '{s}' to '{s}'", .{ cwd, input_path });
    std.log.info(" - adding '{s}", .{abs_path});

    return id;
}

pub fn fileTree(self: *const FileStore, id: FileId) std.zig.Ast {
    return self.files.items(.tree)[id.toIndex()];
}

pub fn fileSource(self: *const FileStore, id: FileId) [:0]const u8 {
    return self.files.items(.source)[id.toIndex()];
}

pub fn fileAbsPath(self: *const FileStore, id: FileId) []const u8 {
    return self.files.items(.abs_path)[id.toIndex()];
}

pub fn filePosition(self: *const FileStore, id: FileId, byte_offset: usize) FilePosition {
    const source = self.files.items(.source)[id.toIndex()];
    const line_starts = self.files.items(.line_starts)[id.toIndex()];
    std.debug.assert(byte_offset <= source.len);

    const line = lineNumber(
        line_starts,
        byte_offset,
    );
    return .{
        .line = line,
        .column = byte_offset - line_starts[line],
    };
}

pub fn fileRange(
    self: *const FileStore,
    id: FileId,
    start_byte_offset: usize,
    end_byte_offset: usize,
) FileRange {
    return .{
        .start = self.filePosition(
            id,
            start_byte_offset,
        ),
        .end = self.filePosition(
            id,
            end_byte_offset,
        ),
    };
}

fn allocLineStarts(allocator: std.mem.Allocator, source: []const u8) ![]const usize {
    var line_starts: std.ArrayList(usize) = .empty;
    errdefer line_starts.deinit(allocator);

    try line_starts.append(allocator, 0);
    for (source, 0..) |char, i|
        if (char == '\n' and i + 1 <= source.len)
            try line_starts.append(allocator, i + 1);

    return try line_starts.toOwnedSlice(allocator);
}

fn lineNumber(line_starts: []const usize, byte_offset: usize) usize {
    var lo: usize = 0;
    var hi: usize = line_starts.len;

    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (line_starts[mid] <= byte_offset)
            lo = mid + 1
        else
            hi = mid;
    }

    return if (lo == 0) 0 else lo - 1;
}

test "filePosition resolves line and column via cached line starts" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.zig",
        .data = "abc\nxy\r\nz",
    });

    var session_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session_arena.deinit();
    var file_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer file_arena.deinit();
    var rule_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rule_arena.deinit();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try tmp_dir.dir.realPath(std.testing.io, &cwd_buffer)];
    const fake_args = Args.testDefault();

    const runtime: LintRuntime = .{
        .io = std.testing.io,
        .verbose = false,
        .args = &fake_args,
        .session_arena = &session_arena,
        .file_arena = &file_arena,
        .rule_arena = &rule_arena,
        .zig_exe = "zig",
        .zig_lib_directory = ".",
        .cwd = cwd,
    };

    var file_store = FileStore.init(&runtime);
    const file_id = try file_store.resolve("sample.zig");

    try std.testing.expectEqualDeep(
        FilePosition{ .line = 0, .column = 0 },
        file_store.filePosition(file_id, 0),
    );
    try std.testing.expectEqualDeep(
        FilePosition{ .line = 0, .column = 3 },
        file_store.filePosition(file_id, 3),
    );
    try std.testing.expectEqualDeep(
        FilePosition{ .line = 1, .column = 0 },
        file_store.filePosition(file_id, 4),
    );
    try std.testing.expectEqualDeep(
        FilePosition{ .line = 1, .column = 3 },
        file_store.filePosition(file_id, 7),
    );
    try std.testing.expectEqualDeep(
        FilePosition{ .line = 2, .column = 0 },
        file_store.filePosition(file_id, 8),
    );
}

test "fileRange resolves start and end positions" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.writeFile(std.testing.io, .{
        .sub_path = "sample.zig",
        .data = "const value = 1;\n",
    });

    var session_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer session_arena.deinit();
    var file_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer file_arena.deinit();
    var rule_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rule_arena.deinit();

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try tmp_dir.dir.realPath(
        std.testing.io,
        &cwd_buffer,
    )];
    const fake_args = Args.testDefault();

    const runtime: LintRuntime = .{
        .io = std.testing.io,
        .verbose = false,
        .args = &fake_args,
        .session_arena = &session_arena,
        .file_arena = &file_arena,
        .rule_arena = &rule_arena,
        .zig_exe = "zig",
        .zig_lib_directory = ".",
        .cwd = cwd,
    };

    var file_store = FileStore.init(&runtime);
    const file_id = try file_store.resolve("sample.zig");

    try std.testing.expectEqualDeep(
        FileRange{
            .start = .{ .line = 0, .column = 6 },
            .end = .{ .line = 0, .column = 10 },
        },
        file_store.fileRange(file_id, 6, 10),
    );
}

const Args = @import("../Args.zig");
const LintRuntime = @import("LintRuntime.zig");
const std = @import("std");
const tracy = @import("tracy");
const oom = @import("../allocations.zig").oom;
