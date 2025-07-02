/// Returns a list of zig source files that should be linted.
///
/// If an explicit list of file paths was provided in the args, this will be
/// used, otherwise it'll walk relative to working path.
pub fn allocLintFiles(dir: std.fs.Dir, args: zlinter.Args, gpa: std.mem.Allocator) ![]zlinter.LintFile {
    var lint_files = std.ArrayListUnmanaged(zlinter.LintFile).empty;
    defer lint_files.deinit(gpa);

    if (args.files) |files| {
        for (files) |file_or_dir| {
            const sub_dir = dir.openDir(file_or_dir, .{ .iterate = true }) catch |err| {
                switch (err) {
                    else => {
                        const cwd = try std.process.getCwdAlloc(gpa);
                        defer gpa.free(cwd);

                        const relative = try std.fs.path.relative(gpa, cwd, file_or_dir);
                        defer gpa.free(relative);

                        // Assume file.
                        // No validation is done at this point on whether the file
                        // even exists and can be opened as it'll be done when
                        // opening the file for parsing.
                        try lint_files.append(gpa, try .init(gpa, relative));
                        continue;
                    },
                }
            };
            try walkDirectory(
                gpa,
                sub_dir,
                &lint_files,
                file_or_dir,
            );
        }
    } else {
        try walkDirectory(
            gpa,
            dir,
            &lint_files,
            "./",
        );
    }
    return lint_files.toOwnedSlice(gpa);
}

/// Walks a directory and its sub directories adding any zig relative file
/// paths that should be linted to the given `file_paths` set.
fn walkDirectory(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    lint_files: *std.ArrayListUnmanaged(zlinter.LintFile),
    parent_path: []const u8,
) !void {
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |item| {
        if (item.kind != .file) continue;
        if (!zlinter.isLintableFilePath(item.path)) continue;

        try lint_files.append(allocator, zlinter.LintFile{
            .pathname = try std.fs.path.resolve(
                allocator,
                &.{
                    parent_path,
                    item.path,
                },
            ),
        });
    }
}

test "allocLintFiles - with default args" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try testing.createFiles(tmp_dir.dir, @constCast(&[_][]const u8{
        "a.zig",
        "zig",
        ".zig",
        "src/A.zig",
        "src/zig",
        "src/.zig",
        // Zig cache and Zig bin is ignored
        ".zig-cache/a.zig",
        "zig-out/a.zig",
    }));

    const lint_files = try allocLintFiles(tmp_dir.dir, .{}, std.testing.allocator);
    defer {
        for (lint_files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(lint_files);
    }

    try std.testing.expectEqualDeep(&.{
        zlinter.LintFile{
            .pathname = "a.zig",
        },
        zlinter.LintFile{
            .pathname = "src/A.zig",
        },
    }, lint_files);
}

test "allocLintFiles - with arg files" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });

    defer tmp_dir.cleanup();

    try testing.createFiles(tmp_dir.dir, @constCast(&[_][]const u8{
        "a.zig",
        "b.zig",
        "c.zig",
        "d.zig",
        "zig",
        ".zig",
        "src/A.zig",
        "src/zig",
        "src/.zig",
        // Zig cache and Zig bin is ignored
        ".zig-cache/a.zig",
        "zig-out/a.zig",
    }));

    const lint_files = try allocLintFiles(tmp_dir.dir, .{ .files = @constCast(
        &[_][]const u8{
            "a.zig",
            "src/",
        },
    ) }, std.testing.allocator);
    defer {
        for (lint_files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(lint_files);
    }

    try std.testing.expectEqualDeep(&.{
        zlinter.LintFile{
            .pathname = "a.zig",
        },
        zlinter.LintFile{
            .pathname = "src/A.zig",
        },
    }, lint_files);
}

const testing = @import("testing.zig");
const std = @import("std");
const zlinter = @import("./zlinter.zig");
