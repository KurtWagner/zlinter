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
};

/// All evaluated build configurations. Use `buildConfig(...)` and
/// `buildRootPath(...)` to look these up using a resolved configuration id.
configs: std.MultiArrayList(Config) = .empty,

/// An index for efficiently looking up what configuration is associated with
/// a given source path or build root path. This is used internally by `resolve`
/// and should never be used externally.
config_id_by_path: std.StringHashMapUnmanaged(ConfigId) = .empty,

runtime: *const LintRuntime,

pub fn init(runtime: *const LintRuntime) BuildConfigStore {
    return .{
        .runtime = runtime,
    };
}

/// Resolves a given directory or source path to the current or ancestor
/// directory that contains `build.zig` and generate a build configuration
/// for said path if it doesn't already exist.
///
/// Returns an id that can be used in `buildRootPath` and `buildConfig`
/// to lookup resolved information.
pub fn resolve(
    self: *BuildConfigStore,
    input_path: []const u8,
) error{ResolutionError}!ConfigId {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.resolve");
    defer zone.end();

    const io = self.runtime.io;
    const session_arena = self.runtime.sessionArena();

    // 2x as we use it for generating two paths.
    var fba_buffer: [std.Io.Dir.max_path_bytes * 2]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = std.Io.Dir.path.resolve(
        fba.allocator(),
        &.{ self.runtime.cwd, input_path },
    ) catch unreachable;

    if (self.config_id_by_path.get(normal_path)) |index|
        return index;

    const build_root = self.findBuildRoot(io, normal_path) catch |e| {
        std.log.err("Could not find build root from '{s}' due to {t}", .{
            normal_path,
            e,
        });
        return error.ResolutionError;
    };

    const build_root_path = switch (build_root) {
        .config_id => |cached| {
            self.cacheResolvedConfigPaths(
                normal_path,
                cached.path,
                cached.index,
            );
            return cached.index;
        },
        .path => |path| path,
    };
    std.log.info(" = Root: {s}", .{build_root_path});

    const config_path = files.resolveBuildConfigurationPath(
        io,
        fba.allocator(),
        self.runtime.zig_exe,
        build_root_path,
    ) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM"),
        else => {
            std.log.err("Could not resolve build configuration path for '{s}' using '{s}' due to {t}", .{
                build_root_path,
                self.runtime.zig_exe,
                e,
            });
            return error.ResolutionError;
        },
    };

    var file = std.Io.Dir.cwd().openFile(
        io,
        config_path,
        .{},
    ) catch |e| {
        std.log.err("Could not find config file '{s}' due to {t}", .{ config_path, e });
        return error.ResolutionError;
    };
    defer file.close(io);

    const config = std.Build.Configuration.loadFile(
        session_arena,
        io,
        file,
    ) catch |e| switch (e) {
        error.OutOfMemory => @panic("OOM"),
        else => {
            std.log.err("Failed to load configuration file due to: {t}", .{e});
            return error.ResolutionError;
        },
    };

    const build_root_key = oom(session_arena.dupe(u8, build_root_path));
    const config_id: ConfigId = .fromIndex(self.configs.len);

    oom(self.configs.append(session_arena, .{
        .build_config = config,
        .build_root_path = build_root_key,
    }));

    oom(self.config_id_by_path.putNoClobber(session_arena, build_root_key, config_id));
    self.cacheResolvedConfigPaths(normal_path, build_root_key, config_id);

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
fn findBuildRoot(
    self: *const BuildConfigStore,
    io: std.Io,
    src_path: []const u8,
) !BuildRoot {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.findBuildRoot");
    defer zone.end();

    var dir = src_path;

    while (true) {
        std.log.info(" -- checking '{s}'", .{dir});
        if (self.config_id_by_path.get(dir)) |index|
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

        const parent = std.Io.Dir.path.dirname(dir) orelse ".";
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
fn cacheResolvedConfigPaths(
    self: *BuildConfigStore,
    src_path: []const u8,
    cached_ancestor_path: []const u8,
    config_id: ConfigId,
) void {
    const zone = tracy.traceNamed(@src(), "BuildConfigStore.cacheResolvedConfigPaths");
    defer zone.end();

    const config_index = config_id.toIndex();
    std.debug.assert(config_index < self.configs.len);

    var path = src_path;

    while (!std.mem.eql(u8, path, cached_ancestor_path)) {
        if (!self.config_id_by_path.contains(path)) {
            const key = oom(self.runtime.sessionArena().dupe(u8, path));
            oom(self.config_id_by_path.putNoClobber(self.runtime.sessionArena(), key, config_id));
        }

        const parent = std.Io.Dir.path.dirname(path) orelse cached_ancestor_path;
        if (std.mem.eql(u8, parent, path))
            break;

        path = parent;
    }
}

const files = @import("../files.zig");
const LintRuntime = @import("LintRuntime.zig");
const std = @import("std");
const tracy = @import("tracy");
const oom = @import("../allocations.zig").oom;
