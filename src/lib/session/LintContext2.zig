const LintContext2 = @This();

pub const CompileContextId = enum(u32) { _ };

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
    try self.consumeRootBuildConfig(config_id);
}

fn consumeRootBuildConfig(self: *LintContext2, config_id: BuildConfigStore.ConfigId) !void {
    const build_root_path = self.build_config_store.buildRootPath(config_id);
    const root_build_config = self.build_config_store.buildConfig(config_id);

    std.log.info("Init context with {d} steps", .{root_build_config.steps.len});
    for (root_build_config.steps, 0..) |_, step_index|
        try self.consumeRootBuildConfigStep(
            root_build_config,
            build_root_path,
            step_index,
        );
}

fn consumeRootBuildConfigStep(
    self: *LintContext2,
    root_build_config: *const std.Build.Configuration,
    build_root_path: []const u8,
    step_index: usize,
) !void {
    const step = root_build_config.steps[step_index];
    const compile = step.extended.cast(
        root_build_config,
        std.Build.Configuration.Step.Compile,
    ) orelse return;

    const compile_name = try self.gpa.dupe(u8, step.name.slice(root_build_config));
    errdefer self.gpa.free(compile_name);

    const root_module = compile.root_module.get(root_build_config);
    const root_module_root_source_file: ?FileStore.FileId = path: {
        const id = root_module.root_source_file.unwrap() orelse break :path null;

        const abs_path = try files.resolveLazyPath(
            id.get(root_build_config),
            root_build_config,
            self.gpa,
            build_root_path,
        ) orelse break :path null;
        defer self.gpa.free(abs_path);

        break :path try self.file_store.resolve(
            abs_path,
            self.io,
            self.gpa,
            self.cwd,
        );
    };

    if (root_module_root_source_file) |root_file_id| {
        var named_imports: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;
        errdefer named_imports.deinit(self.gpa);

        const imports = root_module.import_table.get(root_build_config).imports.mal;

        try named_imports.ensureTotalCapacity(self.gpa, @intCast(imports.len));
        for (imports.items(.name), imports.items(.module)) |
            build_import_name_id,
            build_import_module_id,
        | {
            const import_module = build_import_module_id.get(root_build_config);

            const import_file_id = import_module.root_source_file.unwrap() orelse continue;
            const import_file = import_file_id.get(root_build_config);
            const import_path = try files.resolveLazyPath(
                import_file,
                root_build_config,
                self.gpa,
                build_root_path,
            ) orelse continue;
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

            const import_name = try self.gpa.dupe(u8, build_import_name_id.slice(root_build_config));
            errdefer self.gpa.free(import_name);

            named_imports.putAssumeCapacity(
                import_name,
                import_module_id,
            );
        }

        const compile_context_id: CompileContext.Id = .fromIndex(self.compile_contexts.len);
        const target = compile.rootModuleTarget(root_build_config);
        const root_module_id = try self.module_store.resolve(
            self.gpa,
            .{
                .root_file = root_file_id,
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

        // Populate map:
        // ------ Start ------
        {
            var map: std.AutoHashMapUnmanaged(FileStore.FileId, void) = .empty;
            defer map.deinit(self.gpa);

            var it: files.ImportIterator = .{
                .file_store = &self.file_store,
                .io = self.io,
                .cwd = std.fs.path.dirname(self.file_store.fileAbsPath(root_file_id)) orelse
                    @panic("TODO: Should this be unreachable or cwd"),
                .gpa = self.gpa,
                .zig_lib_directory = self.zig_lib_directory,
            };
            defer it.deinit();

            try it.init(root_file_id);
            while (try it.next()) |descendent_file_id| {
                try map.put(self.gpa, descendent_file_id, {});
                std.debug.print(" Visited Descendent: '{s}'\n", .{self.file_store.fileAbsPath(descendent_file_id)});
            }
        }
        // ------ End ------
    } else {
        std.log.info("Step {d} has no root source path", .{step_index});
    }
}

pub fn deinit(self: *LintContext2) void {
    for (self.compile_contexts.items(.name)) |name| {
        self.gpa.free(name);
    }

    self.build_config_store.deinit(self.gpa);
    self.file_store.deinit(self.gpa);
    self.compile_contexts.deinit(self.gpa);
    self.module_store.deinit(self.gpa);
}

pub fn resolveFile(self: *LintContext2, input_path: []const u8) !FileStore.FileId {
    return self.file_store.resolve(input_path, self.io, self.gpa, self.cwd);
}

pub const CompiledContextIterator = struct {
    ctx: *const LintContext2,
    file_id: FileStore.FileId,

    index: usize = 0,

    pub fn next(self: *CompiledContextIterator) ?CompileContext.Id {
        while (self.index < self.ctx.compile_contexts.len) {
            const index = self.index;
            self.index += 1;

            _ = index;
            // TODO: #149 - bring back
            // if (self.ctx.include_descendents.items[index].contains(self.file_id)) {
            //     return @intCast(index);
            // }
        }
        return null;
    }
};

pub fn resolveCompiledUnits(
    self: *const LintContext2,
    file_id: FileStore.FileId,
) CompiledContextIterator {
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
