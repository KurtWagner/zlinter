const LintContext2 = @This();

pub const CompileContextId = enum(u32) { _ };

const StepIndex = u32;

environ_map: *const std.process.Environ.Map,
gpa: std.mem.Allocator,
arena: std.mem.Allocator,
io: std.Io,
zig_exe: []const u8,
zig_lib_directory: []const u8,
cwd: []const u8,

compile_contexts: std.MultiArrayList(CompileContext) = .empty,
build_config_store: BuildConfigStore = .empty,
file_store: FileStore = .empty,
module_store: ModuleStore = .empty,

// TODO: #149 - should really be multi array type instead of sep arrays
include_steps: std.ArrayList(std.Build.Configuration.Step.Index) = .empty,
include_root_source_abs_path: std.ArrayList([]const u8) = .empty,
include_root_import_map: std.ArrayList(std.StringHashMapUnmanaged(FileStore.FileId)) = .empty,
include_descendents: std.ArrayList(std.AutoHashMapUnmanaged(FileStore.FileId, void)) = .empty,

pub const LintContextOptions = struct {};

// TODO: #149 - Add optional arg for compiled units from args
pub fn init(self: *LintContext2, options: LintContextOptions) !void {
    const zone = tracy.traceNamed(@src(), "LintContext2.init");
    defer zone.end();

    _ = options;

    const config_id = try self.build_config_store.resolve(
        self.io,
        self.gpa,
        self.zig_exe,
        self.cwd,
        ".",
    );
    const build_root_path = self.build_config_store.buildRootPath(config_id);
    const root_build_config = self.build_config_store.buildConfig(config_id);

    std.log.info("Init context with {d} steps", .{root_build_config.steps.len});
    for (root_build_config.steps, 0..) |step, step_index| {
        const compile = step.extended.cast(
            root_build_config,
            std.Build.Configuration.Step.Compile,
        ) orelse continue;

        const compile_step_index: std.Build.Configuration.Step.Index = @enumFromInt(step_index);

        const compile_name = try self.gpa.dupe(u8, step.name.slice(root_build_config));
        errdefer self.gpa.free(compile_name);

        std.log.info("Step {d} - '{s}' (root name:'{s}')", .{
            step_index,
            compile_name,
            compile.root_name.slice(root_build_config),
        });

        // TODO: Print the import table ""

        const root_module = compile.root_module.get(root_build_config);

        if (root_module.root_source_file.unwrap()) |root_source_file_id| {
            const root_source_file = root_source_file_id.get(root_build_config);

            if (try files.resolveLazyPath(
                root_source_file,
                root_build_config,
                self.gpa,
                build_root_path,
            )) |abs_path| {
                const file_id = try self.file_store.resolve(
                    abs_path,
                    self.io,
                    self.gpa,
                    self.cwd,
                );
                std.log.info(
                    "Step {d} root source path: '{s}'",
                    .{ step_index, abs_path },
                );

                var named_imports: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;
                errdefer named_imports.deinit(self.gpa);

                const imports = root_module.import_table.get(root_build_config).imports.mal;
                try named_imports.ensureTotalCapacity(self.gpa, @intCast(imports.len));
                for (imports.items(.name), imports.items(.module)) |
                    import_name,
                    import_module_index,
                | {
                    const import_module = import_module_index.get(root_build_config);
                    const import_source_file_id = import_module.root_source_file.unwrap() orelse continue;
                    const import_source_file = import_source_file_id.get(root_build_config);
                    const import_path = (try files.resolveLazyPath(
                        import_source_file,
                        root_build_config,
                        self.gpa,
                        build_root_path,
                    )) orelse continue;
                    defer self.gpa.free(import_path);

                    const import_module_id = try self.module_store.resolve(
                        self.gpa,
                        .{
                            .root_file = try self.file_store.resolve(
                                import_path,
                                self.io,
                                self.gpa,
                                self.cwd,
                            ),
                            // TODO: #149 - do we want to go deeper?
                            .named_imports = .empty,
                        },
                    );
                    named_imports.putAssumeCapacity(
                        import_name.slice(root_build_config),
                        import_module_id,
                    );
                }

                const compile_context_id: CompileContext.Id = .fromIndex(self.compile_contexts.len);
                const target = compile.rootModuleTarget(root_build_config);
                const root_module_id = try self.module_store.resolve(
                    self.gpa,
                    .{
                        .root_file = file_id,
                        .named_imports = named_imports,
                    },
                );
                try self.compile_contexts.append(self.gpa, .{
                    .name = compile_name,
                    .kind = compile.flags3.kind,
                    .root_module = root_module_id,
                    .target = .{
                        .cpu_arch = target.flags.cpu_arch.unwrap().?,
                        .os_tag = target.flags.os_tag.unwrap().?,
                        .abi = target.flags.abi.unwrap().?,
                    },
                });
                errdefer _ = self.compile_contexts.swapRemove(compile_context_id.toIndex());

                std.debug.assert(self.include_steps.items.len == self.include_root_source_abs_path.items.len);
                std.debug.assert(self.include_steps.items.len == self.include_root_import_map.items.len);
                std.debug.assert(self.include_steps.items.len == self.include_descendents.items.len);

                try self.include_steps.append(self.gpa, compile_step_index);
                try self.include_root_source_abs_path.append(self.gpa, abs_path);
                try self.appendImportMap(compile_step_index, config_id);

                // Populate map:
                // ------ Start ------
                {
                    var map: std.AutoHashMapUnmanaged(FileStore.FileId, void) = .empty;
                    errdefer map.deinit(self.gpa);

                    var it: files.ImportIterator = .{
                        .file_store = &self.file_store,
                        .io = self.io,
                        .cwd = std.fs.path.dirname(self.file_store.fileAbsPath(file_id)) orelse
                            @panic("TODO: Should this be unreachable or cwd"),
                        .gpa = self.gpa,
                        .zig_lib_directory = self.zig_lib_directory,
                    };
                    defer it.deinit();

                    try it.init(file_id);
                    while (try it.next()) |descendent_file_id| {
                        try map.put(self.gpa, descendent_file_id, {});
                        std.debug.print(" Visited Descendent: '{s}'\n", .{self.file_store.fileAbsPath(descendent_file_id)});
                    }

                    try self.include_descendents.append(self.gpa, map);
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

pub fn deinit(self: *LintContext2) void {
    for (self.compile_contexts.items(.name)) |name| {
        self.gpa.free(name);
    }

    for (self.include_root_source_abs_path.items) |path| {
        self.gpa.free(path);
    }

    for (self.include_root_import_map.items) |*map| {
        var it = map.keyIterator();
        while (it.next()) |key| self.gpa.free(key.*);
        map.deinit(self.gpa);
    }
    for (self.include_descendents.items) |*map| {
        map.deinit(self.gpa);
    }

    self.include_descendents.deinit(self.gpa);
    self.include_root_import_map.deinit(self.gpa);
    self.include_root_source_abs_path.deinit(self.gpa);
    self.include_steps.deinit(self.gpa);
    self.build_config_store.deinit(self.gpa);
    self.file_store.deinit(self.gpa);
    self.compile_contexts.deinit(self.gpa);
    self.module_store.deinit(self.gpa);
}

pub fn resolveFile(self: *LintContext2, input_path: []const u8) !FileStore.FileId {
    return self.file_store.resolve(input_path, self.io, self.gpa, self.cwd);
}

pub const CompiledUnitIterator = struct {
    ctx: *const LintContext2,
    file_id: FileStore.FileId,

    step_index: StepIndex = 0,

    pub fn next(self: *CompiledUnitIterator) ?StepIndex {
        while (self.step_index < self.ctx.include_descendents.items.len) {
            const step_index = self.step_index;
            self.step_index += 1;

            if (self.ctx.include_descendents.items[step_index].contains(self.file_id)) {
                return @intCast(step_index);
            }
        }
        return null;
    }
};

pub fn resolveCompiledUnits(
    self: *const LintContext2,
    file_id: FileStore.FileId,
) CompiledUnitIterator {
    return .{
        .ctx = self,
        .file_id = file_id,
    };
}

fn appendImportMap(
    self: *LintContext2,
    step_index: std.Build.Configuration.Step.Index,
    config_id: BuildConfigStore.ConfigId,
) !void {
    const root_build_config = self.build_config_store.buildConfig(config_id);
    const build_root_path = self.build_config_store.buildRootPath(config_id);

    const step = root_build_config.steps[@intFromEnum(step_index)];
    const compile = step.extended.cast(
        root_build_config,
        std.Build.Configuration.Step.Compile,
    ) orelse unreachable;

    const root_module = compile.root_module.get(root_build_config);
    const imports = root_module.import_table.get(root_build_config).imports.mal;

    var import_map: std.StringHashMapUnmanaged(FileStore.FileId) = .empty;
    errdefer import_map.deinit(self.gpa);

    for (imports.items(.name), imports.items(.module)) |import_name, import_module_index| {
        const import_module = import_module_index.get(root_build_config);
        if (import_module.root_source_file.unwrap()) |import_source_file_id| {
            const import_source_file = import_source_file_id.get(root_build_config);
            if (try files.resolveLazyPath(
                import_source_file,
                root_build_config,
                self.gpa,
                build_root_path,
            )) |import_path| {
                defer self.gpa.free(import_path);

                const file_id = try self.file_store.resolve(
                    import_path,
                    self.io,
                    self.gpa,
                    self.cwd,
                );

                const name = try self.gpa.dupe(
                    u8,
                    import_name.slice(root_build_config),
                );
                errdefer self.gpa.free(name);

                try import_map.put(self.gpa, name, file_id);

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

    try self.include_root_import_map.append(self.gpa, import_map);
}

const std = @import("std");
const files = @import("../files.zig");
const BuildConfigStore = @import("BuildConfigStore.zig");
const FileStore = @import("FileStore.zig");
const ModuleStore = @import("ModuleStore.zig");
const CompileContext = @import("CompileContext.zig");
const tracy = @import("tracy");
