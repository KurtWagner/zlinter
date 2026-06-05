const LintContext2 = @This();

environ_map: *const std.process.Environ.Map,
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
io: std.Io,
zig_exe: []const u8,

bcs: BuildConfigStore = .empty,

root_build_config: std.Build.Configuration = undefined, // Set in init().
include_steps: std.ArrayList(std.Build.Configuration.Step.Index) = .empty,
include_root_source_files: std.ArrayList([]const u8) = .empty,

// TODO: #149 - Add optional arg for compiled units from args
pub fn init(ctx: *LintContext2) !void {
    const build_root_path = try findNearestBuildRootPath(
        ctx.io,
        ".",
    );

    ctx.root_build_config = try ctx.resolveBuildConfig(
        ctx.arena,
        build_root_path,
    );

    for (ctx.root_build_config.steps, 0..) |step, step_index| {
        const compile = step.extended.cast(
            &ctx.root_build_config,
            std.Build.Configuration.Step.Compile,
        ) orelse continue;

        const compile_step_index: std.Build.Configuration.Step.Index = @enumFromInt(step_index);
        const compile_name = step.name.slice(&ctx.root_build_config);

        std.debug.print("'{s}' '{s}' {d}\n", .{
            compile_name,
            compile.root_name.slice(&ctx.root_build_config),
            compile_step_index,
        });

        const root_module = compile.root_module.get(&ctx.root_build_config);
        if (root_module.root_source_file.unwrap()) |root_source_file_index| {
            const root_source_file = root_source_file_index.get(&ctx.root_build_config);

            if (try files.resolveLazyPath(
                root_source_file,
                &ctx.root_build_config,
                ctx.gpa,
                build_root_path,
            )) |path| {
                std.debug.print(" - '{s}'\n", .{path});

                try ctx.include_steps.append(ctx.gpa, compile_step_index);
                try ctx.include_root_source_files.append(ctx.gpa, path);
            }
        }
    }
}

pub fn deinit(ctx: *LintContext2) void {
    for (ctx.include_root_source_files.items) |path| {
        ctx.gpa.free(path);
    }

    ctx.include_steps.deinit(ctx.gpa);
    ctx.bcs.deinit(ctx.gpa);
}

fn resolveBuildConfig(
    ctx: *const LintContext2,
    arena: std.mem.Allocator,
    build_root_path: []const u8,
) !std.Build.Configuration {
    const config_path = try files.resolveBuildConfigurationPath(
        ctx.io,
        ctx.gpa,
        ctx.zig_exe,
        build_root_path,
    );
    defer ctx.gpa.free(config_path);

    var file = try std.Io.Dir.cwd().openFile(
        ctx.io,
        config_path,
        .{},
    );
    defer file.close(ctx.io);

    return try std.Build.Configuration.loadFile(
        arena,
        ctx.io,
        file,
    );
}

fn findNearestBuildRootPath(io: std.Io, src_dir: []const u8) ![]const u8 {
    var dir = src_dir;

    while (true) {
        if (try files.hasBuildZig(io, dir))
            return dir;

        const parent = std.fs.path.dirname(dir) orelse ".";
        if (std.mem.eql(u8, parent, dir))
            return error.FileNotFound;

        dir = parent;
    }
}

const std = @import("std");
const files = @import("../files.zig");
const BuildConfigStore = @import("BuildConfigStore.zig");
