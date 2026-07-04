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

    var fba_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = oom(std.fs.path.resolve(
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

    const tree = oom(std.zig.Ast.parse(session_arena, source, .zig));
    const abs_path = oom(session_arena.dupe(u8, normal_path));
    const id: FileId = .fromIndex(self.files.len);

    oom(self.files.append(session_arena, .{
        .tree = tree,
        .abs_path = abs_path,
        .source = source,
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

const LintRuntime = @import("LintRuntime.zig");
const std = @import("std");
const tracy = @import("tracy");
const oom = @import("../allocations.zig").oom;
