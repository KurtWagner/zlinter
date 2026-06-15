const BuildConfigStore = @This();

pub const ConfigId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) ConfigId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: ConfigId) usize {
        return @intFromEnum(self);
    }
};

pub const Config = struct {
    /// Evaluated build configuration.
    build_config: std.Build.Configuration,

    /// Build root path used to load this config.
    build_root_path: []const u8,

    /// Arena associated with the allocated configuration. Used to clean up data
    /// associated with this configuration.
    arena: std.heap.ArenaAllocator,
};

/// All evaluated build configurations. Use `buildConfig(...)` and
/// `buildRootPath(...)` to look these up using a resolved configuration id.
configs: std.MultiArrayList(Config),

/// An index for efficiently looking up what configuration is associated with
/// a given source path or build root path. This is used internally by `resolve`
/// and should never be used externally.
path_to_config: std.StringHashMapUnmanaged(ConfigId),

pub const empty: BuildConfigStore = .{
    .configs = .empty,
    .path_to_config = .empty,
};

pub fn deinit(self: *BuildConfigStore, gpa: std.mem.Allocator) void {
    for (self.configs.items(.arena)) |arena|
        arena.deinit();

    self.configs.deinit(gpa);
    self.path_to_config.deinit(gpa);
}

/// Resolves a given directory or source path to the current or ancestor
/// directory that contains `build.zig` and generate a build configuration
/// for said path if it doesn't already exist.
///
/// Returns an id that can be used in `buildRootPath` and `buildConfig`
/// to lookup resolved information.
pub fn resolve(
    self: *BuildConfigStore,
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    cwd: []const u8,
    input_path: []const u8,
) !ConfigId {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.resolve");
    defer zone.end();

    var fba_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = std.fs.path.resolve(
        fba.allocator(),
        &.{ cwd, input_path },
    ) catch unreachable;

    // TODO: #147 - log based on verbosity
    std.log.info("Resolving '{s}'", .{normal_path});

    if (self.path_to_config.get(normal_path)) |index|
        return index;

    const build_root = try self.findNearestBuildRoot(io, normal_path);

    const build_root_path = switch (build_root) {
        .config_id => |cached| {
            try self.cacheResolvedPaths(gpa, normal_path, cached.path, cached.index);
            return cached.index;
        },
        .path => |path| path,
    };
    std.log.info(" = Root: {s}", .{build_root_path});

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

    const config_id: ConfigId = .fromIndex(self.configs.len);

    try self.configs.append(gpa, .{
        .build_config = config,
        .build_root_path = build_root_key,
        .arena = arena,
    });
    errdefer _ = self.configs.swapRemove(config_id.toIndex());

    try self.path_to_config.putNoClobber(gpa, build_root_key, config_id);
    errdefer _ = self.path_to_config.remove(build_root_key);

    try self.cacheResolvedPaths(gpa, normal_path, build_root_key, config_id);

    return config_id;
}

/// Returns build root path (where build.zig is) for a given id, use
/// `resolve` to get a config id for a given file or directory.
pub fn buildRootPath(self: *const BuildConfigStore, id: ConfigId) []const u8 {
    const index = id.toIndex();
    std.debug.assert(index < self.configs.len);
    return self.configs.items(.build_root_path)[index];
}

/// Returns build configuration for a given id, use `resolve` to get
/// a config id for a given file or directory.
pub fn buildConfig(self: *const BuildConfigStore, id: ConfigId) *const std.Build.Configuration {
    const index = id.toIndex();
    std.debug.assert(index < self.configs.len);
    return &self.configs.items(.build_config)[index];
}

const BuildRoot = union(enum) {
    config_id: struct {
        index: ConfigId,
        path: []const u8,
    },
    path: []const u8,
};

/// Finds the nearest ancestor of `src_path` that can provide a build
/// configuration.
///
/// The result is either a directory containing `build.zig`, or an already
/// cached path that resolves to an existing configuration. Returning the cached
/// path lets `resolve` backfill any missing descendant cache entries between the
/// original source path and that ancestor.
fn findNearestBuildRoot(
    self: *const BuildConfigStore,
    io: std.Io,
    src_path: []const u8,
) !BuildRoot {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.findNearestBuildRoot");
    defer zone.end();

    var dir = src_path;

    while (true) {
        std.log.info(" -- checking '{s}'", .{dir});
        if (self.path_to_config.get(dir)) |index|
            return .{ .config_id = .{
                .index = index,
                .path = dir,
            } };

        const maybe_open_dir: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, dir, .{}) catch |err|
            switch (err) {
                error.FileNotFound, error.NotDir => null,
                else => |e| return e,
            };
        if (maybe_open_dir) |open_dir| {
            defer open_dir.close(io);
            if (try files.hasBuildZig(io, open_dir))
                return .{ .path = dir };
        }

        const parent = std.fs.path.dirname(dir) orelse ".";
        if (std.mem.eql(u8, parent, dir)) {
            std.log.err("Could not find build.zig for '{s}'", .{src_path});
            return error.FileNotFound;
        }

        dir = parent;
    }
}

/// Caches `src_path` and any uncached ancestors up to `cached_ancestor_path` as
/// aliases for `config_id`.
///
/// `cached_ancestor_path` must already be known to resolve to `config_id`.
/// This lets future resolves for nearby descendants stop at the closest cached
/// ancestor instead of probing every parent directory for `build.zig`.
fn cacheResolvedPaths(
    self: *BuildConfigStore,
    gpa: std.mem.Allocator,
    src_path: []const u8,
    cached_ancestor_path: []const u8,
    config_id: ConfigId,
) !void {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.cacheResolvedPaths");
    defer zone.end();

    const config_index = config_id.toIndex();
    std.debug.assert(config_index < self.configs.len);

    var path = src_path;
    const arena = self.configs.items(.arena)[config_index].allocator();

    while (!std.mem.eql(u8, path, cached_ancestor_path)) {
        if (!self.path_to_config.contains(path)) {
            const key = try arena.dupe(u8, path);
            errdefer arena.free(key);

            try self.path_to_config.putNoClobber(gpa, key, config_id);
        }

        const parent = std.fs.path.dirname(path) orelse cached_ancestor_path;
        if (std.mem.eql(u8, parent, path))
            break;

        path = parent;
    }
}

const files = @import("../files.zig");
const std = @import("std");
const tracy = @import("tracy");
