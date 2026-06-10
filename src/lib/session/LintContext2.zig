const LintContext2 = @This();

const StepIndex = u32;

environ_map: *const std.process.Environ.Map,
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
io: std.Io,
zig_exe: []const u8,
zig_lib_directory: []const u8,
cwd: []const u8,

build_config_store: BuildConfigStore = .empty,
file_store: FileStore = .empty,

// TODO: #149 - should really be multi array type instead of sep arrays
include_steps: std.ArrayList(std.Build.Configuration.Step.Index) = .empty,
include_root_source_abs_path: std.ArrayList([]const u8) = .empty,
include_root_import_map: std.ArrayList(std.StringHashMapUnmanaged(FileStore.FileId)) = .empty,
include_descendents: std.ArrayList(std.AutoHashMapUnmanaged(FileStore.FileId, void)) = .empty,

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

    std.log.info("Init context with {d} steps", .{root_build_config.steps.len});
    for (root_build_config.steps, 0..) |step, step_index| {
        const compile = step.extended.cast(
            root_build_config,
            std.Build.Configuration.Step.Compile,
        ) orelse continue;

        const compile_step_index: std.Build.Configuration.Step.Index = @enumFromInt(step_index);
        const compile_name = step.name.slice(root_build_config);

        std.log.info("Step {d} - '{s}' (root name:'{s}')", .{
            step_index,
            compile_name,
            compile.root_name.slice(root_build_config),
        });

        const root_module = compile.root_module.get(root_build_config);

        if (root_module.root_source_file.unwrap()) |root_source_file_index| {
            const root_source_file = root_source_file_index.get(root_build_config);

            if (try files.resolveLazyPath(
                root_source_file,
                root_build_config,
                ctx.gpa,
                build_root_path,
            )) |abs_path| {
                const file_index = try ctx.file_store.resolve(
                    abs_path,
                    ctx.io,
                    ctx.gpa,
                    ctx.cwd,
                );
                std.log.info(
                    "Step {d} root source path: '{s}'",
                    .{ step_index, abs_path },
                );

                std.debug.assert(ctx.include_steps.items.len == ctx.include_root_source_abs_path.items.len);
                std.debug.assert(ctx.include_steps.items.len == ctx.include_root_import_map.items.len);
                std.debug.assert(ctx.include_steps.items.len == ctx.include_descendents.items.len);

                try ctx.include_steps.append(ctx.gpa, compile_step_index);
                try ctx.include_root_source_abs_path.append(ctx.gpa, abs_path);
                try ctx.appendImportMap(compile_step_index, config_index);

                // Populate map:
                // ------ Start ------
                {
                    var map: std.AutoHashMapUnmanaged(FileStore.FileId, void) = .empty;
                    errdefer map.deinit(ctx.gpa);

                    var it: files.ImportIterator = .{
                        .file_store = &ctx.file_store,
                        .io = ctx.io,
                        .cwd = std.fs.path.dirname(ctx.file_store.fileAbsPath(file_index)) orelse
                            @panic("TODO: Should this be unreachable or cwd"),
                        .gpa = ctx.gpa,
                        .zig_lib_directory = ctx.zig_lib_directory,
                    };
                    defer it.deinit();

                    try it.init(file_index);
                    while (try it.next()) |descendent_file_index| {
                        try map.put(ctx.gpa, descendent_file_index, {});
                        std.debug.print(" Visited Descendent: '{s}'\n", .{ctx.file_store.fileAbsPath(descendent_file_index)});
                    }

                    try ctx.include_descendents.append(ctx.gpa, map);
                }
                // ------ End ------
            } else {
                std.log.info("Step {d} has no root source path", .{step_index});
            }
        } else {
            std.log.info("Step {d} no root module", .{step_index});
        }
    }
}

pub fn deinit(ctx: *LintContext2) void {
    for (ctx.include_root_source_abs_path.items) |path| {
        ctx.gpa.free(path);
    }

    for (ctx.include_root_import_map.items) |*map| {
        var it = map.keyIterator();
        while (it.next()) |key| ctx.gpa.free(key.*);
        map.deinit(ctx.gpa);
    }
    for (ctx.include_descendents.items) |*map| {
        map.deinit(ctx.gpa);
    }

    ctx.include_descendents.deinit(ctx.gpa);
    ctx.include_root_import_map.deinit(ctx.gpa);
    ctx.include_root_source_abs_path.deinit(ctx.gpa);
    ctx.include_steps.deinit(ctx.gpa);
    ctx.build_config_store.deinit(ctx.gpa);
    ctx.file_store.deinit(ctx.gpa);
}

pub fn resolveFile(ctx: *LintContext2, input_path: []const u8) !FileStore.FileId {
    return ctx.file_store.resolve(input_path, ctx.io, ctx.gpa, ctx.cwd);
}

pub const CompiledUnitIterator = struct {
    ctx: *const LintContext2,
    file_index: FileStore.FileId,

    step_index: StepIndex = 0,

    pub fn next(it: *CompiledUnitIterator) ?StepIndex {
        while (it.step_index < it.ctx.include_descendents.items.len) {
            const step_index = it.step_index;
            it.step_index += 1;

            if (it.ctx.include_descendents.items[step_index].contains(it.file_index)) {
                return @intCast(step_index);
            }
        }
        return null;
    }
};

pub fn resolveCompiledUnits(
    ctx: *const LintContext2,
    file_index: FileStore.FileId,
) CompiledUnitIterator {
    return .{
        .ctx = ctx,
        .file_index = file_index,
    };
}

fn appendImportMap(
    ctx: *LintContext2,
    step_index: std.Build.Configuration.Step.Index,
    config_index: BuildConfigStore.ConfigId,
) !void {
    const root_build_config = ctx.build_config_store.buildConfig(config_index);
    const build_root_path = ctx.build_config_store.buildRootPath(config_index);

    const step = root_build_config.steps[@intFromEnum(step_index)];
    const compile = step.extended.cast(
        root_build_config,
        std.Build.Configuration.Step.Compile,
    ) orelse unreachable;

    const root_module = compile.root_module.get(root_build_config);
    const imports = root_module.import_table.get(root_build_config).imports.mal;

    var import_map: std.StringHashMapUnmanaged(FileStore.FileId) = .empty;
    errdefer import_map.deinit(ctx.gpa);

    for (imports.items(.name), imports.items(.module)) |import_name, import_module_index| {
        const import_module = import_module_index.get(root_build_config);
        if (import_module.root_source_file.unwrap()) |import_source_file_index| {
            const import_source_file = import_source_file_index.get(root_build_config);
            if (try files.resolveLazyPath(
                import_source_file,
                root_build_config,
                ctx.gpa,
                build_root_path,
            )) |import_path| {
                defer ctx.gpa.free(import_path);

                const file_index = try ctx.file_store.resolve(
                    import_path,
                    ctx.io,
                    ctx.gpa,
                    ctx.cwd,
                );

                const name = try ctx.gpa.dupe(
                    u8,
                    import_name.slice(root_build_config),
                );
                errdefer ctx.gpa.free(name);

                try import_map.put(ctx.gpa, name, file_index);

                std.log.info(
                    "Step {d} import '{s}' root source '{s}' resolved",
                    .{
                        @intFromEnum(step_index),
                        import_name.slice(root_build_config),
                        import_path,
                    },
                );
            } else {
                std.log.info(
                    "Step {d} import '{s}' root source could not be resolved",
                    .{
                        @intFromEnum(step_index),
                        import_name.slice(root_build_config),
                    },
                );
            }
        } else {
            std.log.info(
                "Step {d} import '{s}' has no root source file",
                .{ @intFromEnum(step_index), import_name.slice(root_build_config) },
            );
        }
    }

    try ctx.include_root_import_map.append(ctx.gpa, import_map);
}

const std = @import("std");
const files = @import("../files.zig");
const BuildConfigStore = @import("BuildConfigStore.zig");
const FileStore = @import("FileStore.zig");
const tracy = @import("tracy");
