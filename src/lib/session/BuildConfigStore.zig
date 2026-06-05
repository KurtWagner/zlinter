const BuildConfigStore = @This();

root_config: u32,

/// All evaluated build configurations. You can look these up from `dirs`
configs: std.ArrayList(std.Build.Configuration),

/// All evlauated build root paths used to load configs
build_roots: std.ArrayList([]const u8),

/// Arenas associated with the allocated configurations in `configs`.
arenas: std.ArrayList(std.heap.ArenaAllocator),

/// Maps a resolved build directory path to `configs` and `arenas`.
dirs: std.StringHashMapUnmanaged(u32),

/// Compiled steps discovered while evaluating build configurations
root_compiled_steps: std.ArrayList(*const std.Build.Configuration.Step.Compile),

/// Contains all paths found in compiled steps mapping to an index that can
/// be used to find parent compiled steps in `root_path_index`.
root_compiled_paths: std.StringArrayHashMapUnmanaged(u32),

/// Contains a bitset indicating the compiled steps that this path is in.
root_path_index: std.ArrayList(std.StaticBitSet(32)),

pub const empty: BuildConfigStore = .{
    .configs = .empty,
    .build_roots = .empty,
    .arenas = .empty,
    .dirs = .empty,
    .root_compiled_steps = .empty,
    .root_compiled_paths = .empty,
    .root_path_index = .empty,

    // TODO: #149 - Can't assume 0?
    .root_config = 0,
};

pub fn deinit(bcs: *BuildConfigStore, gpa: std.mem.Allocator) void {
    var path_it = bcs.root_compiled_paths.iterator();
    while (path_it.next()) |kv| {
        gpa.free(kv.key_ptr.*);
    }
    bcs.root_compiled_steps.deinit(gpa);
    bcs.root_compiled_paths.deinit(gpa);
    bcs.root_path_index.deinit(gpa);

    for (bcs.arenas.items) |arena|
        arena.deinit();

    bcs.configs.deinit(gpa);
    bcs.arenas.deinit(gpa);
    bcs.dirs.deinit(gpa);
    bcs.build_roots.deinit(gpa);
}

pub fn lookup(
    bcs: *BuildConfigStore,
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_exe: []const u8,
    src_path: []const u8,
) !struct { []const u8, *const std.Build.Configuration } {
    var fba_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buffer);

    const normal_path = try std.fs.path.resolve(fba.allocator(), &.{src_path});
    const source_dir = std.fs.path.dirname(normal_path) orelse ".";
    const build_root = try bcs.findNearestBuildRoot(io, source_dir);

    const build_root_path = switch (build_root) {
        .index => |index| return .{
            bcs.build_roots.items[index],
            &bcs.configs.items[index],
        },
        .path => |path| path,
    };

    const config_path = try files.resolveBuildConfigurationPath(io, gpa, zig_exe, build_root_path);
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

    const build_root_key = try arena.allocator().dupe(u8, build_root_path);
    errdefer arena.allocator().free(build_root_key);

    try bcs.configs.append(gpa, config);
    try bcs.arenas.append(gpa, arena);
    try bcs.build_roots.append(gpa, build_root_key);
    std.debug.assert(bcs.configs.items.len == bcs.arenas.items.len and
        bcs.arenas.items.len == bcs.build_roots.items.len);

    try bcs.dirs.putNoClobber(gpa, build_root_key, @intCast(bcs.configs.items.len - 1));

    try bcs.walkBuildConfig(&config, build_root_path, gpa);

    return .{ build_root_key, &bcs.configs.items[bcs.configs.items.len - 1] };
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

        if (try files.hasBuildZig(io, dir))
            return .{ .path = dir };

        const parent = std.fs.path.dirname(dir) orelse ".";
        if (std.mem.eql(u8, parent, dir))
            return error.FileNotFound;

        dir = parent;
    }
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

            if (try files.resolveLazyPath(
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

/// Walks imports but only relative paths not modules
/// NOT IMPLEMENTED YET OR USED
const RelativeImportIterator = struct {
    queue: std.ArrayList([]const u8),
    root: []const u8,
    gpa: std.mem.Allocator,

    fn init(root: []const u8, gpa: std.mem.Allocator) RelativeImportIterator {
        return .{
            .root = root,
            .queue = .empty,
            .gpa = gpa,
        };
    }

    fn next(walker: *RelativeImportIterator) !?[]const u8 {
        if (walker.queue.pop()) |path| {
            defer walker.gpa.free(path);
            try walker.visit(path);
            return path;
        }
        return null;
    }
};

const files = @import("../files.zig");
const std = @import("std");
