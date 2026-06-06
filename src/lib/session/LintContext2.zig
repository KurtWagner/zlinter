const LintContext2 = @This();

environ_map: *const std.process.Environ.Map,
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
io: std.Io,
zig_exe: []const u8,
cwd: []const u8,

build_config_store: BuildConfigStore = .empty,
file_store: FileStore = .empty,

include_steps: std.ArrayList(std.Build.Configuration.Step.Index) = .empty,
include_root_source_files: std.ArrayList([]const u8) = .empty,

pub const LintContextOptions = struct {};

// TODO: #149 - Add optional arg for compiled units from args
pub fn init(ctx: *LintContext2, options: LintContextOptions) !void {
    const zone = tracy.traceNamed(@src(), "LintContext2.init");
    defer zone.end();

    _ = options;

    const config_index = try ctx.build_config_store.resolve(
        ctx.io,
        ctx.gpa,
        ctx.zig_exe,
        ctx.cwd,
        ".",
    );
    const build_root_path = ctx.build_config_store.buildRootPath(config_index);
    const root_build_config = ctx.build_config_store.buildConfig(config_index);

    for (root_build_config.steps, 0..) |step, step_index| {
        const compile = step.extended.cast(
            root_build_config,
            std.Build.Configuration.Step.Compile,
        ) orelse continue;

        const compile_step_index: std.Build.Configuration.Step.Index = @enumFromInt(step_index);
        const compile_name = step.name.slice(root_build_config);

        std.debug.print("'{s}' '{s}' {d}\n", .{
            compile_name,
            compile.root_name.slice(root_build_config),
            compile_step_index,
        });

        const root_module = compile.root_module.get(root_build_config);
        if (root_module.root_source_file.unwrap()) |root_source_file_index| {
            const root_source_file = root_source_file_index.get(root_build_config);

            if (try files.resolveLazyPath(
                root_source_file,
                root_build_config,
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

    ctx.include_root_source_files.deinit(ctx.gpa);
    ctx.include_steps.deinit(ctx.gpa);
    ctx.build_config_store.deinit(ctx.gpa);
    ctx.file_store.deinit(ctx.gpa);
}

const std = @import("std");
const files = @import("../files.zig");
const BuildConfigStore = @import("BuildConfigStore.zig");
const FileStore = @import("FileStore.zig");
const tracy = @import("tracy");
