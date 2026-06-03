const BuildConfigStore = @This();

cache: std.StringHashMapUnmanaged(CacheEntry),

const CacheEntry = struct {
    config: std.Build.Configuration,
    arena: std.heap.ArenaAllocator,
};

pub const empty: BuildConfigStore = .{
    .cache = .empty,
};

pub fn deinit(bcs: *BuildConfigStore, gpa: std.mem.Allocator) void {
    var it = bcs.cache.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        entry.value_ptr.arena.deinit();
    }
    bcs.cache.deinit(gpa);
}

pub fn lookup(
    bcs: *BuildConfigStore,
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    src_path: []const u8,
) !*const std.Build.Configuration {
    var fba_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = try std.fs.path.resolve(fba.allocator(), &.{src_path});
    const source_dir = std.fs.path.dirname(normal_path) orelse ".";
    const build_root = try findNearestBuildRoot(io, source_dir);

    if (bcs.cache.getPtr(build_root)) |cache_entry|
        return &cache_entry.config;

    const config_path_result = try std.process.run(gpa, io, .{
        .argv = &.{
            zig_exe,
            "build",
            "--print-configuration-path",
        },
        .cwd = .{ .path = build_root },
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

    const config_path = try resolveConfigurationPath(
        gpa,
        build_root,
        std.mem.trim(u8, config_path_result.stdout, " \t\r\n"),
    );
    defer gpa.free(config_path);

    var file = try std.Io.Dir.cwd().openFile(
        io,
        config_path,
        .{},
    );
    defer file.close(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    const config = try std.Build.Configuration.loadFile(
        arena.allocator(),
        io,
        file,
    );
    errdefer arena.deinit();

    const build_root_key = try gpa.dupe(u8, build_root);
    errdefer gpa.free(build_root_key);

    try bcs.cache.putNoClobber(gpa, build_root_key, .{
        .config = config,
        .arena = arena,
    });
    return &bcs.cache.getPtr(build_root_key).?.config;
}

fn hasBuildZig(io: std.Io, dir_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch |err|
        switch (err) {
            error.FileNotFound => return false,
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

fn findNearestBuildRoot(io: std.Io, src_dir: []const u8) ![]const u8 {
    var dir = src_dir;

    while (true) {
        if (try hasBuildZig(io, dir))
            return dir;

        const parent = std.fs.path.dirname(dir) orelse ".";

        if (std.mem.eql(u8, parent, dir))
            return error.FileNotFound;

        dir = parent;
    }
}

fn resolveConfigurationPath(
    gpa: std.mem.Allocator,
    build_root: []const u8,
    config_path: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(config_path)) return gpa.dupe(u8, config_path);
    return std.fs.path.join(gpa, &.{ build_root, config_path });
}

const std = @import("std");
