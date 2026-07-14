//! Utilities for interacting with filesystem

/// Location of a source file to lint
pub const LintFile = struct {
    /// Absolute normalized path used for identity and filesystem operations.
    /// This memory is owned and free'd in `deinit`.
    abs_path: []const u8,

    /// Whether or not the path was resolved but subsequently excluded by
    /// an exclude path argument. If this is true, the file should NOT be linted
    excluded: bool = false,

    pub fn deinit(self: *LintFile, allocator: std.mem.Allocator) void {
        allocator.free(self.abs_path);
        self.* = undefined;
    }
};

/// Returns a list of zig source files that should be linted.
///
/// If an explicit list of file paths was provided in the args, this will be
/// used, otherwise it'll walk relative to working path.
pub fn allocLintFiles(
    io: std.Io,
    dir: std.Io.Dir,
    maybe_files: ?[]const []const u8,
    gpa: std.mem.Allocator,
) ![]zlinter.files.LintFile {
    var file_paths = std.StringHashMap(void).init(gpa);
    defer file_paths.deinit();
    errdefer {
        var cleanup_it = file_paths.keyIterator();
        while (cleanup_it.next()) |abs_path| gpa.free(abs_path.*);
    }

    var root_abs_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_abs_path = root_abs_path_buffer[0..try dir.realPath(io, &root_abs_path_buffer)];

    if (maybe_files) |files| {
        for (files) |file_or_dir| {
            const abs_path = try std.Io.Dir.path.resolve(gpa, &.{
                root_abs_path,
                file_or_dir,
            });

            const sub_dir = dir.openDir(io, file_or_dir, .{ .iterate = true }) catch {
                // Assume file if we can't open as directory:
                // No validation is done at this point on whether the file
                // even exists and can be opened as it'll be done when
                // opening the file for parsing so don't double up...
                try putLintFilePath(gpa, &file_paths, abs_path);
                continue;
            };
            defer sub_dir.close(io);

            walkDirectory(
                io,
                gpa,
                sub_dir,
                &file_paths,
                abs_path,
            ) catch |err| {
                gpa.free(abs_path);
                return err;
            };
            gpa.free(abs_path);
        }
    } else {
        try walkDirectory(
            io,
            gpa,
            dir,
            &file_paths,
            root_abs_path,
        );
    }

    var lint_files = try gpa.alloc(zlinter.files.LintFile, file_paths.count());
    errdefer gpa.free(lint_files);

    var i: usize = 0;
    var it = file_paths.keyIterator();
    while (it.next()) |abs_path| {
        lint_files[i] = .{
            .abs_path = abs_path.*,
        };
        i += 1;
    }

    return lint_files;
}

/// Returns an index of files to exclude if exclude configuration is found in args.
pub fn buildExcludesIndex(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    args: Args,
) !?std.BufSet {
    if (args.exclude_paths == null and args.build_exclude_paths == null) return null;

    const exclude_lint_paths: ?[]LintFile = exclude: {
        if (args.exclude_paths) |paths| {
            std.debug.assert(paths.len > 0);
            break :exclude try allocLintFiles(io, dir, paths, arena);
        } else break :exclude null;
    };
    defer if (exclude_lint_paths) |files| {
        for (files) |*lint_file| lint_file.deinit(arena);
        arena.free(files);
    };

    const build_exclude_lint_paths: ?[]LintFile = exclude: {
        // User include paths supersede build configured includes and excludes.
        if (args.include_paths != null) break :exclude null;

        if (args.build_exclude_paths) |paths| {
            std.debug.assert(paths.len > 0);
            break :exclude try allocLintFiles(io, dir, paths, arena);
        } else break :exclude null;
    };
    defer if (build_exclude_lint_paths) |files| {
        for (files) |*lint_file| lint_file.deinit(arena);
        arena.free(files);
    };

    var index = std.BufSet.init(arena);
    errdefer index.deinit();

    if (exclude_lint_paths) |files|
        for (files) |file| try index.insert(file.abs_path);

    if (build_exclude_lint_paths) |files|
        for (files) |file| try index.insert(file.abs_path);

    return index;
}

/// Returns an index of files to only include if filter configuration is found in args.
pub fn buildFilterIndex(
    io: std.Io,
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    args: Args,
) !?std.BufSet {
    const filter_paths: []LintFile = exclude: {
        if (args.filter_paths) |paths| {
            std.debug.assert(paths.len > 0);
            break :exclude try allocLintFiles(io, dir, paths, arena);
        } else return null;
    };
    defer {
        for (filter_paths) |*lint_file| lint_file.deinit(arena);
        arena.free(filter_paths);
    }

    var index = std.BufSet.init(arena);
    errdefer index.deinit();

    for (filter_paths) |file| try index.insert(file.abs_path);
    return index;
}

/// Walks a directory and its sub directories adding any zig source file
/// paths that should be linted to the given `file_paths` set.
fn walkDirectory(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    file_paths: *std.StringHashMap(void),
    parent_abs_path: []const u8,
) !void {
    std.debug.assert(std.Io.Dir.path.isAbsolute(parent_abs_path));

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        if (!try isLintableFilePath(item.path)) continue;

        const resolved = try std.Io.Dir.path.resolve(
            allocator,
            &.{
                parent_abs_path,
                item.path,
            },
        );
        errdefer allocator.free(resolved);

        try putLintFilePath(allocator, file_paths, resolved);
    }
}

fn putLintFilePath(
    allocator: std.mem.Allocator,
    file_paths: *std.StringHashMap(void),
    abs_path: []const u8,
) !void {
    std.debug.assert(std.Io.Dir.path.isAbsolute(abs_path));

    errdefer allocator.free(abs_path);

    if (file_paths.contains(abs_path)) {
        allocator.free(abs_path);
    } else {
        try file_paths.putNoClobber(abs_path, {});
    }
}

pub fn isLintableFilePath(file_path: []const u8) !bool {
    const extension = ".zig";

    const basename = std.Io.Dir.path.basename(file_path);
    if (basename.len <= extension.len) return false; // Can't just be ".zig"
    if (!std.mem.endsWith(u8, basename, extension)) return false;

    var components = std.Io.Dir.path.componentIterator(file_path);
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
    }) |file_path|
        try std.testing.expect(try isLintableFilePath(testing.paths.posix(file_path)));

    // Bad extensions:
    inline for (&.{
        ".zig",
        "file.zi",
        "file.z",
        "file.",
        "zig",
        "src/.zig",
        "src/zig",
    }) |file_path|
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));

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
    }) |file_path|
        try std.testing.expect(!try isLintableFilePath(testing.paths.posix(file_path)));
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

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try tmp_dir.dir.realPath(std.testing.io, &cwd_buffer)];

    const lint_files = try allocLintFiles(std.testing.io, tmp_dir.dir, null, std.testing.allocator);
    defer {
        for (lint_files) |*file| file.deinit(std.testing.allocator);
        std.testing.allocator.free(lint_files);
    }

    try std.testing.expectEqual(2, lint_files.len);
    const cwd_rel_path_0 = try std.Io.Dir.path.relative(std.testing.allocator, cwd, null, cwd, lint_files[0].abs_path);
    defer std.testing.allocator.free(cwd_rel_path_0);

    const cwd_rel_path_1 = try std.Io.Dir.path.relative(std.testing.allocator, cwd, null, cwd, lint_files[1].abs_path);
    defer std.testing.allocator.free(cwd_rel_path_1);

    try testing.expectContainsExactlyStrings(&.{
        testing.paths.posix("a.zig"),
        testing.paths.posix("src/A.zig"),
    }, &.{ cwd_rel_path_0, cwd_rel_path_1 });
    try std.testing.expect(std.Io.Dir.path.isAbsolute(lint_files[0].abs_path));
    try std.testing.expect(std.Io.Dir.path.isAbsolute(lint_files[1].abs_path));
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

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try tmp_dir.dir.realPath(std.testing.io, &cwd_buffer)];

    const lint_files = try allocLintFiles(std.testing.io, tmp_dir.dir, &.{
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
    const cwd_rel_path_0 = try std.Io.Dir.path.relative(std.testing.allocator, cwd, null, cwd, lint_files[0].abs_path);
    defer std.testing.allocator.free(cwd_rel_path_0);

    const cwd_rel_path_1 = try std.Io.Dir.path.relative(std.testing.allocator, cwd, null, cwd, lint_files[1].abs_path);
    defer std.testing.allocator.free(cwd_rel_path_1);

    try testing.expectContainsExactlyStrings(&.{
        testing.paths.posix("a.zig"),
        testing.paths.posix("src/A.zig"),
    }, &.{ cwd_rel_path_0, cwd_rel_path_1 });
    try std.testing.expect(std.Io.Dir.path.isAbsolute(lint_files[0].abs_path));
    try std.testing.expect(std.Io.Dir.path.isAbsolute(lint_files[1].abs_path));
}

test "buildExcludesIndex prefers user include over build excludes" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try testing.createFiles(tmp_dir.dir, @constCast(&[_][]const u8{
        testing.paths.posix("src/keep.zig"),
        testing.paths.posix("build_only.zig"),
        testing.paths.posix("user_only.zig"),
    }));

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try tmp_dir.dir.realPath(std.testing.io, &cwd_buffer)];
    var args = Args.testDefault();
    args.include_paths = @constCast(&[_][]const u8{testing.paths.posix("src")});
    args.exclude_paths = @constCast(&[_][]const u8{testing.paths.posix("user_only.zig")});
    args.build_exclude_paths = @constCast(&[_][]const u8{testing.paths.posix("build_only.zig")});

    var index = (try buildExcludesIndex(std.testing.io, std.testing.allocator, tmp_dir.dir, args)).?;
    defer index.deinit();

    const user_only = try std.Io.Dir.path.resolve(std.testing.allocator, &.{ cwd, testing.paths.posix("user_only.zig") });
    defer std.testing.allocator.free(user_only);
    const build_only = try std.Io.Dir.path.resolve(std.testing.allocator, &.{ cwd, testing.paths.posix("build_only.zig") });
    defer std.testing.allocator.free(build_only);

    try std.testing.expect(index.contains(user_only));
    try std.testing.expect(!index.contains(build_only));
}

test "buildFilterIndex resolves filter files into absolute path index" {
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();

    try testing.createFiles(tmp_dir.dir, @constCast(&[_][]const u8{
        testing.paths.posix("src/a.zig"),
        testing.paths.posix("src/b.zig"),
        testing.paths.posix("other/c.zig"),
    }));

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buffer[0..try tmp_dir.dir.realPath(
        std.testing.io,
        &cwd_buffer,
    )];
    var args = Args.testDefault();
    args.filter_paths = @constCast(&[_][]const u8{
        testing.paths.posix("src/a.zig"),
        testing.paths.posix("other"),
    });

    var index = (try buildFilterIndex(
        std.testing.io,
        std.testing.allocator,
        tmp_dir.dir,
        args,
    )).?;
    defer index.deinit();

    const a = try std.Io.Dir.path.resolve(
        std.testing.allocator,
        &.{ cwd, testing.paths.posix("src/a.zig") },
    );
    defer std.testing.allocator.free(a);
    const c = try std.Io.Dir.path.resolve(
        std.testing.allocator,
        &.{ cwd, testing.paths.posix("other/c.zig") },
    );
    defer std.testing.allocator.free(c);
    const b = try std.Io.Dir.path.resolve(
        std.testing.allocator,
        &.{ cwd, testing.paths.posix("src/b.zig") },
    );
    defer std.testing.allocator.free(b);

    try std.testing.expect(index.contains(a));
    try std.testing.expect(index.contains(c));
    try std.testing.expect(!index.contains(b));
}

/// Returns true if the directory contains a "build.zig" file.
pub fn hasBuildZig(io: std.Io, dir: std.Io.Dir) !bool {
    const stat = dir.statFile(io, "build.zig", .{}) catch |err|
        switch (err) {
            error.FileNotFound => return false,
            else => |e| return e,
        };
    return stat.kind == .file;
}

test "hasBuildZig - with build.zig" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    (try tmp_dir.dir.createFile(std.testing.io, "build.zig", .{})).close(std.testing.io);
    try std.testing.expect(try hasBuildZig(std.testing.io, tmp_dir.dir));
}

test "hasBuildZig - without build.zig" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try std.testing.expect(!try hasBuildZig(std.testing.io, tmp_dir.dir));
}

test "hasBuildZig - build.zig is not a file" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "build.zig");

    try std.testing.expect(!try hasBuildZig(std.testing.io, tmp_dir.dir));
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
        .stdout_limit = .limited(std.Io.Dir.max_path_bytes + 1),
        .stderr_limit = .limited(1024 * 1024),
    });

    defer {
        gpa.free(config_path_result.stderr);
        gpa.free(config_path_result.stdout);
    }
    switch (config_path_result.term) {
        .exited => |code| if (code != 0) {
            std.log.err("{s}", .{config_path_result.stderr});
            return error.ConfigurationLookupFailed;
        },
        else => {
            std.log.err("{s}", .{config_path_result.stderr});
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
    if (std.Io.Dir.path.isAbsolute(config_path)) return gpa.dupe(u8, config_path);
    return std.Io.Dir.path.join(gpa, &.{ build_root, config_path });
}

pub fn resolveLazyPath(
    path: std.Build.Configuration.LazyPath,
    config: *const std.Build.Configuration,
    build_root_path: []const u8,
    buffer: []u8,
) !?[]const u8 {
    var fba: std.heap.FixedBufferAllocator = .init(buffer);
    switch (path) {
        .source_path => |source_path| {
            const root = if (source_path.owner.get(config)) |pkg|
                pkg.root_path.slice(config)
            else
                build_root_path;

            return try std.Io.Dir.path.resolve(
                fba.allocator(),
                &.{ root, source_path.sub_path.slice(config) },
            );
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
            return try std.Io.Dir.path.resolve(
                fba.allocator(),
                &.{ root, sub_path },
            );
        },
        .generated => return null,
    }
}

/// Converts a local file URI to an absolute path.
///
/// Returns null if `uri` is not a file URI or refers to a remote host.
/// The caller owns the returned path. Panics if allocation fails.
pub fn fileUriToAbsPath(
    allocator: std.mem.Allocator,
    uri: std.Uri,
) ?[]u8 {
    if (!std.mem.eql(u8, uri.scheme, "file"))
        return null;

    if (uri.host) |host| {
        const host_text = switch (host) {
            .raw => |value| value,
            .percent_encoded => |value| value,
        };

        if (host_text.len != 0 and
            !std.ascii.eqlIgnoreCase(host_text, "localhost"))
            return null;
    }

    return switch (uri.path) {
        .raw => |value| allocator.dupe(u8, value) catch @panic("OOM"),
        .percent_encoded => |value| std.Uri.percentDecodeInPlace(
            allocator.dupe(u8, value) catch @panic("OOM"),
        ),
    };
}

const Args = @import("Args.zig");
const std = @import("std");
const testing = @import("testing.zig");
const zlinter = @import("./zlinter.zig");

test {
    std.testing.refAllDecls(@This());
}
