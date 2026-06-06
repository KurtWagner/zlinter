const BuildConfigStore = @This();

pub const ConfigIndex = u32;

/// All evaluated build configurations. Use `buildConfig(...)` to look these
/// up using a resolved configuration index.
build_configs: std.ArrayList(std.Build.Configuration),

/// All evaluated build root paths used to load configs. Use `buildRootPath(...)`
/// to look these up using a resolve configuration path.
build_root_paths: std.ArrayList([]const u8),

/// Arenas associated with the allocated configurations in `configs`. These
/// are used to cleanup data (configs and paths) associated with a given a
/// given configuration.
arenas: std.ArrayList(std.heap.ArenaAllocator),

/// An index for efficiently looking up what configuration is associated with
/// a given build root path. This is used internally by `resolve` and should
/// never be used externally.
build_root_path_to_config: std.StringHashMapUnmanaged(ConfigIndex),

pub const empty: BuildConfigStore = .{
    .build_configs = .empty,
    .build_root_paths = .empty,
    .arenas = .empty,
    .build_root_path_to_config = .empty,
};

pub fn deinit(bcs: *BuildConfigStore, gpa: std.mem.Allocator) void {
    for (bcs.arenas.items) |arena|
        arena.deinit();

    bcs.build_configs.deinit(gpa);
    bcs.arenas.deinit(gpa);
    bcs.build_root_path_to_config.deinit(gpa);
    bcs.build_root_paths.deinit(gpa);
}

/// Resolves a given directory or source path to the current or ancestor
/// directory that contains `build.zig` and generate a build configuration
/// for said path if it doesn't already exist.
///
/// Returns an index that can be used in `buildRootPath` and `buildConfig`
/// to lookup resolved information.
pub fn resolve(
    bcs: *BuildConfigStore,
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    cwd: []const u8,
    src_path: []const u8,
) !ConfigIndex {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.resolve");
    defer zone.end();

    var fba_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = std.fs.path.resolve(
        fba.allocator(),
        &.{ cwd, src_path },
    ) catch unreachable;

    // TODO: #147 - log based on verbosity
    std.debug.print("Resolving '{s}'\n", .{normal_path});

    if (bcs.build_root_path_to_config.get(normal_path)) |index|
        return index;

    const build_root = try bcs.findNearestBuildRoot(io, normal_path);

    const build_root_path = switch (build_root) {
        .config_index => |index| return index,
        .path => |path| path,
    };
    std.debug.print(" = Root: {s}\n", .{build_root_path});

    // TODO: #147 - catch and report build errors appropriately otherwise it appears as missing build config...
    const config_path = try files.resolveBuildConfigurationPath(
        io,
        gpa,
        zig_exe,
        build_root_path,
    );
    defer gpa.free(config_path);

    var file = std.Io.Dir.cwd().openFile(
        io,
        config_path,
        .{},
    ) catch |e| {
        switch (e) {
            error.FileNotFound => {
                std.log.err("Could not find config file '{s}'", .{config_path});
                return e;
            },
            else => return e,
        }
    };
    defer file.close(io);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    const config = try std.Build.Configuration.loadFile(
        arena.allocator(),
        io,
        file,
    );
    errdefer arena.deinit();

    const build_root_key = try arena.allocator().dupe(u8, build_root_path);
    errdefer arena.allocator().free(build_root_key);

    std.debug.assert(bcs.build_configs.items.len == bcs.arenas.items.len and
        bcs.arenas.items.len == bcs.build_root_paths.items.len);

    const config_index: ConfigIndex = @intCast(bcs.build_configs.items.len);

    try bcs.build_configs.append(gpa, config);
    errdefer _ = bcs.build_configs.swapRemove(config_index);

    try bcs.arenas.append(gpa, arena);
    errdefer _ = bcs.arenas.swapRemove(config_index);

    try bcs.build_root_paths.append(gpa, build_root_key);
    errdefer _ = bcs.build_root_paths.swapRemove(config_index);

    try bcs.build_root_path_to_config.putNoClobber(gpa, build_root_key, config_index);
    errdefer _ = bcs.build_root_path_to_config.remove(build_root_key);

    return config_index;
}

/// Returns build root path (where build.zig is) for a given index, use
/// `resolve` to get a config index for a given file or directory.
pub fn buildRootPath(bcs: *const BuildConfigStore, index: ConfigIndex) []const u8 {
    std.debug.assert(index < bcs.build_root_paths.items.len);
    return bcs.build_root_paths.items[index];
}

/// Returns build configuration for a given index, use `resolve` to get
/// a config index for a given file or directory.
pub fn buildConfig(bcs: *const BuildConfigStore, index: ConfigIndex) *const std.Build.Configuration {
    std.debug.assert(index < bcs.build_configs.items.len);
    return &bcs.build_configs.items[index];
}

const BuildRoot = union(enum) {
    config_index: ConfigIndex,
    path: []const u8,
};

fn findNearestBuildRoot(
    bcs: *const BuildConfigStore,
    io: std.Io,
    src_path: []const u8,
) !BuildRoot {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.findNearestBuildRoot");
    defer zone.end();

    var dir = src_path;

    while (true) {
        std.debug.print(" -- checking '{s}'\n", .{dir});
        if (bcs.build_root_path_to_config.get(dir)) |index|
            return .{ .config_index = index };

        if (try files.hasBuildZig(io, dir))
            return .{ .path = dir };

        const parent = std.fs.path.dirname(dir) orelse ".";
        if (std.mem.eql(u8, parent, dir)) {
            std.log.err("Could not find build.zig for '{s}'", .{src_path});
            return error.FileNotFound;
        }

        dir = parent;
    }
}

const files = @import("../files.zig");
const std = @import("std");
const tracy = @import("tracy");
