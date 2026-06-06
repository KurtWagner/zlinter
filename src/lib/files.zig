//! Utilities for interacting with filesystem

/// Location of a source file to lint
pub const LintFile = struct {
    /// Path to the file relative to the execution of the linter. This memory
    /// is owned and free'd in `deinit`.
    pathname: []const u8,

    /// Whether or not the path was resolved but subsequently excluded by
    /// an exclude path argument. If this is true, the file should NOT be linted
    excluded: bool = false,

    pub fn deinit(self: *LintFile, allocator: std.mem.Allocator) void {
        allocator.free(self.pathname);
        self.* = undefined;
    }
};

/// Returns a list of relative zig source files that should be linted.
///
/// If an explicit list of file paths was provided in the args, this will be
/// used, otherwise it'll walk relative to working path.
pub fn allocLintFiles(io: std.Io, cwd: []const u8, dir: std.Io.Dir, maybe_files: ?[]const []const u8, gpa: std.mem.Allocator) ![]zlinter.files.LintFile {
    var file_paths = std.StringHashMap(void).init(gpa);
    defer file_paths.deinit();

    if (maybe_files) |files| {
        for (files) |file_or_dir| {
            const sub_dir = dir.openDir(io, file_or_dir, .{ .iterate = true }) catch {
                // Assume file if we can't open as directory:
                // No validation is done at this point on whether the file
                // even exists and can be opened as it'll be done when
                // opening the file for parsing so don't double up...
                const relative = try std.fs.path.relative(gpa, cwd, null, cwd, file_or_dir);
                errdefer gpa.free(relative);

                if (file_paths.contains(relative)) {
                    gpa.free(relative);
                } else {
                    try file_paths.putNoClobber(relative, {});
                }
                continue;
            };
            try walkDirectory(
                io,
                gpa,
                sub_dir,
                &file_paths,
                file_or_dir,
            );
        }
    } else {
        try walkDirectory(
            io,
            gpa,
            dir,
            &file_paths,
            "./",
        );
    }

    var lint_files = try gpa.alloc(zlinter.files.LintFile, file_paths.count());
    errdefer gpa.free(lint_files);

    var i: usize = 0;
    var it = file_paths.keyIterator();
    while (it.next()) |f| {
        lint_files[i] = .{ .pathname = f.* };
        i += 1;
    }

    return lint_files;
}

/// Walks a directory and its sub directories adding any zig relative file
/// paths that should be linted to the given `file_paths` set.
fn walkDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    file_paths: *std.StringHashMap(void),
    parent_path: []const u8,
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        if (!try isLintableFilePath(item.path)) continue;

        const resolved = try std.fs.path.resolve(
            allocator,
            &.{
                parent_path,
                item.path,
            },
        );
        errdefer allocator.free(resolved);

        if (file_paths.contains(resolved)) {
            allocator.free(resolved);
        } else {
            try file_paths.putNoClobber(
                resolved,
                {},
            );
        }
    }
}

pub fn isLintableFilePath(file_path: []const u8) !bool {
    const extension = ".zig";

    const basename = std.fs.path.basename(file_path);
    if (basename.len <= extension.len) return false; // Can't just be ".zig"
    if (!std.mem.endsWith(u8, basename, extension)) return false;

    var components = std.fs.path.componentIterator(file_path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".zig-cache")) return false;
        if (std.mem.eql(u8, component.name, "zig-out")) return false;
        if (std.mem.eql(u8, component.name, "zig-pkg")) return false;
    }

    return true;
}

test "isLintableFilePath" {
    // Good:
    inline for (&.{
        "a.zig",
        "file.zig",
        "some/path/file.zig",
        "./some/path/file.zig",
    }) |file_path| {
        try std.testing.expect(try isLintableFilePath(testing.paths.posix(file_path)));
    }

    // Bad extensions:
    inline for (&.{
        ".zig",
        "file.zi",
        "file.z",
        "file.",
        "zig",
        "src/.zig",
        "src/zig",
    }) |file_path| {
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));
    }

    // Bad parent directory
    inline for (&.{
        "zig-out/file.zig",
        "./zig-out/file.zig",
        ".zig-cache/file.zig",
        "./parent/.zig-cache/file.zig",
        "/other/parent/.zig-cache/file.zig",
        "zig-pkg/file.zig",
        "./zig-pkg/file.zig",
        "/other/parent/zig-pkg/file.zig",
    }) |file_path| {
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));
    }
}

test "allocLintFiles - with default args" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    try testing.createFiles(tmp_dir.dir, @constCast(&[_][]const u8{
        testing.paths.posix("a.zig"),
        testing.paths.posix("zig"),
        testing.paths.posix(".zig"),
        testing.paths.posix("src/A.zig"),
        testing.paths.posix("src/zig"),
        testing.paths.posix("src/.zig"),
        // Zig cache and Zig bin is ignored
        testing.paths.posix(".zig-cache/a.zig"),
        testing.paths.posix("zig-out/a.zig"),
    }));

    const lint_files = try allocLintFiles(std.testing.io, cwd, tmp_dir.dir, null, std.testing.allocator);
    defer {
        for (lint_files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(lint_files);
    }

    try std.testing.expectEqual(2, lint_files.len);
    try testing.expectContainsExactlyStrings(&.{
        testing.paths.posix("a.zig"),
        testing.paths.posix("src/A.zig"),
    }, &.{ lint_files[0].pathname, lint_files[1].pathname });
}

test "allocLintFiles - with arg files" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, std.testing.allocator);
    defer std.testing.allocator.free(cwd);

    try testing.createFiles(tmp_dir.dir, @constCast(&[_][]const u8{
        testing.paths.posix("a.zig"),
        testing.paths.posix("b.zig"),
        testing.paths.posix("c.zig"),
        testing.paths.posix("d.zig"),
        testing.paths.posix("zig"),
        testing.paths.posix(".zig"),
        testing.paths.posix("src/A.zig"),
        testing.paths.posix("src/zig"),
        testing.paths.posix("src/.zig"),
        // Zig cache and Zig bin is ignored
        testing.paths.posix(".zig-cache/a.zig"),
        testing.paths.posix("zig-out/a.zig"),
    }));

    const lint_files = try allocLintFiles(std.testing.io, cwd, tmp_dir.dir, &.{
        testing.paths.posix("a.zig"),
        testing.paths.posix("src/"),
        testing.paths.posix("a.zig"), // Duplicate should be ignored
        testing.paths.posix("src/A.zig"), // Duplicate should be ignored
    }, std.testing.allocator);
    defer {
        for (lint_files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(lint_files);
    }

    try std.testing.expectEqual(2, lint_files.len);
    try testing.expectContainsExactlyStrings(&.{
        testing.paths.posix("a.zig"),
        testing.paths.posix("src/A.zig"),
    }, &.{ lint_files[0].pathname, lint_files[1].pathname });
}

// TODO: #149 - write tests for this
pub fn hasBuildZig(io: std.Io, dir_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err|
        switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => |e| return e,
        };
    defer dir.close(io);

    var file = dir.openFile(io, "build.zig", .{}) catch |err|
        switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
    file.close(io);

    return true;
}

pub fn resolveBuildConfigurationPath(
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    build_root_path: []const u8,
) ![]const u8 {
    const config_path_result = try std.process.run(gpa, io, .{
        .argv = &.{
            zig_exe,
            "build",
            "--print-configuration-path",
        },
        .cwd = .{ .path = build_root_path },
        .stdout_limit = .limited(std.fs.max_path_bytes + 1),
        .stderr_limit = .limited(128 * 1024),
    });

    defer {
        gpa.free(config_path_result.stderr);
        gpa.free(config_path_result.stdout);
    }
    switch (config_path_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("{s}", .{config_path_result.stderr});
            return error.ConfigurationLookupFailed;
        },
        else => {
            std.debug.print("{s}", .{config_path_result.stderr});
            return error.ConfigurationLookupFailed;
        },
    }

    return try resolveConfigurationPath(
        gpa,
        build_root_path,
        std.mem.trim(u8, config_path_result.stdout, " \t\r\n"),
    );
}

fn resolveConfigurationPath(
    gpa: std.mem.Allocator,
    build_root: []const u8,
    config_path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(config_path)) return gpa.dupe(u8, config_path);
    return std.fs.path.join(gpa, &.{ build_root, config_path });
}

pub fn resolveLazyPath(
    path: std.Build.Configuration.LazyPath,
    config: *const std.Build.Configuration,
    gpa: std.mem.Allocator,
    build_root_path: []const u8,
) !?[]const u8 {
    switch (path) {
        .source_path => |source_path| {
            const root = if (source_path.owner.get(config)) |pkg|
                pkg.root_path.slice(config)
            else
                build_root_path;

            return try std.fs.path.resolve(gpa, &.{
                root,
                source_path.sub_path.slice(config),
            });
        },
        .relative => |rel| {
            const sub_path = rel.sub_path.slice(config);

            const root = switch (rel.flags.base) {
                .cwd, .build_root => build_root_path,
                .local_cache,
                .global_cache,
                .zig_exe,
                .zig_lib,
                .install_prefix,
                .install_lib,
                .install_bin,
                .install_include,
                => return null,
            };
            return try std.fs.path.resolve(gpa, &.{ root, sub_path });
        },
        .generated => return null,
    }
}

/// Walks imports with no visited or path type checks (module and relative).
pub const ImportIterator = struct {
    /// File store that's NOT owned by the iterator. Iterator will modify it
    /// as part of resolving files but will NOT free it on deinit.
    file_store: *FileStore,

    io: std.Io,
    gpa: std.mem.Allocator,
    zig_lib_directory: []const u8,
    cwd: []const u8,
    seen: std.bit_set.StaticBitSet(10240) = .empty,

    queue: std.ArrayList(FileStore.FileIndex) = .empty,

    pub fn init(it: *ImportIterator, root: FileStore.FileIndex) !void {
        it.seen.set(root);
        try it.queue.append(it.gpa, root);
    }

    pub fn deinit(it: *ImportIterator) void {
        it.queue.deinit(it.gpa);
    }

    pub fn next(it: *ImportIterator) !?FileStore.FileIndex {
        if (it.queue.pop()) |file_index| {
            try it.visit(file_index);
            return file_index;
        }
        return null;
    }

    fn visit(
        it: *ImportIterator,
        file_index: FileStore.FileIndex,
    ) !void {
        const node_count = it.file_store.fileAst(file_index).nodes.len;
        for (0..node_count) |node_index| {
            const node: std.zig.Ast.Node.Index = @enumFromInt(node_index);
            const tree = it.file_store.fileAst(file_index);
            switch (tree.nodeTag(node)) {
                .builtin_call,
                .builtin_call_comma,
                .builtin_call_two,
                .builtin_call_two_comma,
                => try it.handleBuiltinCall(
                    tree,
                    it.gpa,
                    node,
                    file_index,
                ),
                else => {},
            }
        }
    }

    fn handleBuiltinCall(
        it: *ImportIterator,
        tree: *const std.zig.Ast,
        gpa: std.mem.Allocator,
        node: std.zig.Ast.Node.Index,
        file_index: FileStore.FileIndex,
    ) !void {
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return;

        var params_buffer: [2]std.zig.Ast.Node.Index = undefined;
        const params = tree.builtinCallParams(&params_buffer, node) orelse return;
        std.debug.assert(params.len == 1);

        const import_arg = params[0];
        std.debug.assert(tree.nodeTag(import_arg) == .string_literal);

        const import_token = tree.nodeMainToken(import_arg);
        const raw_import = tree.tokenSlice(import_token);

        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);

        const import_path = switch (try std.zig.string_literal.parseWrite(
            &writer,
            raw_import,
        )) {
            .success => import_path: {
                try writer.flush();
                break :import_path writer.buffer[0..writer.end];
            },
            .failure => {
                std.log.warn("Skipping invalid import {s}", .{raw_import});
                return;
            },
        };

        const parent_file_path = it.file_store.filePath(file_index);
        const parent_file_dir = std.fs.path.dirname(parent_file_path) orelse
            @panic("TODO: Should this be unreachable or cwd");

        const maybe_file_id: ?FileStore.FileIndex =
            if (isRelativeZigImport(import_path))
                try it.file_store.resolve(
                    import_path,
                    it.io,
                    it.gpa,
                    parent_file_dir,
                )
            else if (std.mem.eql(u8, import_path, "std"))
                try it.file_store.resolve(
                    "std/std.zig",
                    it.io,
                    it.gpa,
                    it.zig_lib_directory,
                )
            else
                null;

        if (maybe_file_id) |file_id| {
            if (!it.seen.isSet(file_id)) {
                it.seen.set(file_id);
                try it.queue.append(gpa, file_id);
            }
        }
        // TODO: #149 - support std lib and module imports.
    }

    fn isRelativeZigImport(import_path: []const u8) bool {
        return std.mem.endsWith(u8, import_path, ".zig") and !std.fs.path.isAbsolute(import_path);
    }
};

const std = @import("std");
const testing = @import("testing.zig");
const zlinter = @import("./zlinter.zig");
const FileStore = @import("session/FileStore.zig");

test {
    std.testing.refAllDecls(@This());
}
