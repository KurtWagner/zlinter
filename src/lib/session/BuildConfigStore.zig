const BuildConfigStore = @This();

configs: std.ArrayList(std.Build.Configuration),
arenas: std.ArrayList(std.heap.ArenaAllocator),
dirs: std.StringHashMapUnmanaged(u32),

pub const empty: BuildConfigStore = .{
    .configs = .empty,
    .arenas = .empty,
    .dirs = .empty,
};

pub fn deinit(bcs: *BuildConfigStore, gpa: std.mem.Allocator) void {
    var it = bcs.dirs.keyIterator();
    while (it.next()) |key|
        gpa.free(key.*);
    bcs.dirs.deinit(gpa);

    for (bcs.arenas.items) |arena|
        arena.deinit();

    bcs.configs.deinit(gpa);
    bcs.arenas.deinit(gpa);
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
    const build_root = try bcs.findNearestBuildRoot(io, source_dir);

    const build_root_path = switch (build_root) {
        .index => |index| return &bcs.configs.items[index],
        .path => |path| path,
    };

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

    const config_path = try resolveConfigurationPath(
        gpa,
        build_root_path,
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

    const build_root_key = try gpa.dupe(u8, build_root_path);
    errdefer gpa.free(build_root_key);

    try bcs.configs.append(gpa, config);
    try bcs.arenas.append(gpa, arena);
    std.debug.assert(bcs.configs.items.len == bcs.arenas.items.len);
    try bcs.dirs.putNoClobber(gpa, build_root_key, @intCast(bcs.configs.items.len - 1));

    try bcs.walkBuildConfig(&config, build_root_path, gpa);

    return &bcs.configs.items[bcs.configs.items.len - 1];
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

const BuildRoot = union(enum) {
    index: u32,
    path: []const u8,
};

fn findNearestBuildRoot(
    bcs: *const BuildConfigStore,
    io: std.Io,
    src_dir: []const u8,
) !BuildRoot {
    var dir = src_dir;

    while (true) {
        if (bcs.dirs.get(dir)) |index|
            return .{ .index = index };

        if (try hasBuildZig(io, dir))
            return .{ .path = dir };

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

fn walkBuildConfig(
    bcs: *BuildConfigStore,
    config: *const std.Build.Configuration,
    build_root_path: []const u8,
    gpa: std.mem.Allocator,
) !void {
    // TODO: #149 - Create a useful graph to link paths to compiled units
    _ = bcs;
    for (config.steps, 0..) |step, step_index| {
        const compile = step.extended.cast(
            config,
            std.Build.Configuration.Step.Compile,
        ) orelse continue;

        const compile_step_index: std.Build.Configuration.Step.Index = @enumFromInt(step_index);
        const compile_name = step.name.slice(config);

        std.debug.print("'{s}' '{s}' {d}\n", .{
            compile_name,
            compile.root_name.slice(config),
            compile_step_index,
        });

        const root_module = compile.root_module.get(config);
        if (root_module.root_source_file.unwrap()) |root_source_file_index| {
            const root_source_file = root_source_file_index.get(config);

            if (try resolveLazyPath(
                root_source_file,
                config,
                gpa,
                build_root_path,
            )) |path| {
                defer gpa.free(path);
                std.debug.print(" - '{s}'\n", .{path});
            }
        }
    }
}

fn resolveLazyPath(
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

const std = @import("std");
