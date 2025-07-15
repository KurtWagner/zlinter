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
    }
};

/// Returns a list of zig source files that should be linted.
///
/// If an explicit list of file paths was provided in the args, this will be
/// used, otherwise it'll walk relative to working path.
pub fn allocLintFiles(dir: std.fs.Dir, maybe_files: ?[]const []const u8, gpa: std.mem.Allocator) ![]zlinter.files.LintFile {
    var file_paths = std.StringHashMapUnmanaged(void).empty;
    defer file_paths.deinit(gpa);

    if (maybe_files) |files| {
        for (files) |file_or_dir| {
            const sub_dir = dir.openDir(file_or_dir, .{ .iterate = true }) catch |err| {
                switch (err) {
                    else => {
                        const cwd = try std.process.getCwdAlloc(gpa);
                        defer gpa.free(cwd);

                        // Assume file.
                        // No validation is done at this point on whether the file
                        // even exists and can be opened as it'll be done when
                        // opening the file for parsing.
                        const relative = try std.fs.path.relative(gpa, cwd, file_or_dir);
                        errdefer gpa.free(relative);
                        if (file_paths.contains(relative)) {
                            gpa.free(relative);
                        } else {
                            try file_paths.putNoClobber(gpa, relative, {});
                        }
                        continue;
                    },
                }
            };
            try walkDirectory(
                gpa,
                sub_dir,
                &file_paths,
                file_or_dir,
            );
        }
    } else {
        try walkDirectory(
            gpa,
            dir,
            &file_paths,
            "./",
        );
    }

    var lint_files = std.ArrayListUnmanaged(zlinter.files.LintFile).empty;
    defer lint_files.deinit(gpa);

    var it = file_paths.keyIterator();
    while (it.next()) |f| {
        try lint_files.append(gpa, .{ .pathname = f.* });
    }

    return lint_files.toOwnedSlice(gpa);
}

/// Walks a directory and its sub directories adding any zig relative file
/// paths that should be linted to the given `file_paths` set.
fn walkDirectory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    file_paths: *std.StringHashMapUnmanaged(void),
    parent_path: []const u8,
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |item| {
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
                allocator,
                resolved,
                {},
            );
        }
    }
}

fn isLintableFilePath(file_path: []const u8) !bool {
    const extension = ".zig";

    const basename = std.fs.path.basename(file_path);
    if (basename.len <= extension.len) return false;
    if (!std.mem.endsWith(u8, basename, extension)) return false;

    var components = try std.fs.path.componentIterator(file_path);
    while (components.next()) |component| {
        if (std.mem.eql(u8, component.name, ".zig-cache")) return false;
        if (std.mem.eql(u8, component.name, "zig-out")) return false;
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
    }) |file_path| {
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));
    }
}

test "allocLintFiles - with default args" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

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

    const lint_files = try allocLintFiles(tmp_dir.dir, null, std.testing.allocator);
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

    const lint_files = try allocLintFiles(tmp_dir.dir, &.{
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

const testing = @import("testing.zig");
const std = @import("std");
const zlinter = @import("./zlinter.zig");
