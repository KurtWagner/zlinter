const LintContext2 = @This();

pub const CompileContextId = enum(u32) { _ };

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
io: std.Io,

/// Externally owned slice to zig executable path
zig_exe: []const u8,

/// Externally owned slice to zig lib directory path
zig_lib_directory: []const u8,

/// Externally owned slice to current working directory
cwd: []const u8,

compile_contexts: std.MultiArrayList(CompileContext) = .empty,
file_store: FileStore = .empty,
module_store: ModuleStore = .empty,
decl_store: DeclStore = .empty,

// TODO: #149 - Probably doesnt need to own this because we only ever expect 1 config
build_config_store: BuildConfigStore = .empty,

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

    const build_config = self.build_config_store.buildConfig(config_id);
    for (0..build_config.steps.len) |step_index|
        try self.consumeBuildConfigStep(
            config_id,
            @enumFromInt(step_index),
        );
}

fn consumeBuildConfigStep(
    self: *LintContext2,
    config_id: BuildConfigStore.ConfigId,
    step_index: std.Build.Configuration.Step.Index,
) !void {
    const build_config = self.build_config_store.buildConfig(config_id);
    const step = build_config.steps[@intFromEnum(step_index)];

    const compile = step.extended.cast(
        build_config,
        std.Build.Configuration.Step.Compile,
    ) orelse return;

    const root_module_id = try self.resolveBuildModule(
        config_id,
        compile.root_module,
    ) orelse {
        std.log.info(
            "Step '{s}' has no root module with a root source path",
            .{step.name.slice(build_config)},
        );
        return;
    };

    const root_file_id = self.module_store.rootFile(root_module_id);

    _ = self.decl_store.store(
        root_file_id,
        &self.file_store,
        self.gpa,
    );

    const compile_context_id: CompileContext.Id = .fromIndex(self.compile_contexts.len);
    try self.compile_contexts.append(self.gpa, .{
        .step_index = step_index,
        .root_module = root_module_id,
    });
    errdefer _ = self.compile_contexts.swapRemove(compile_context_id.toIndex());

    // Populate map:
    // ------ Start ------
    {
        var map: std.AutoHashMapUnmanaged(files.ImportIterator.Import, void) = .empty;
        defer map.deinit(self.gpa);

        var it: files.ImportIterator = .{
            .file_store = &self.file_store,
            .io = self.io,
            .cwd = std.fs.path.dirname(self.file_store.fileAbsPath(root_file_id)).?,
            .gpa = self.gpa,
            .zig_lib_directory = self.zig_lib_directory,
        };
        defer it.deinit();

        try it.init(root_file_id);
        while (try it.next()) |child_import| {
            try map.put(self.gpa, child_import, {});
            std.debug.print(" Visited Descendent: '{t}' '{s}'\n", .{
                child_import.kind,
                self.file_store.fileAbsPath(child_import.file_id),
            });

            // TODO: #149 - just doing this here to test it
            _ = self.decl_store.store(
                child_import.file_id,
                &self.file_store,
                self.gpa,
            );
        }
    }
    // ------ End ------
}

fn resolveBuildModule(
    self: *LintContext2,
    config_id: BuildConfigStore.ConfigId,
    build_module_index: std.Build.Configuration.Module.Index,
) !?ModuleStore.ModuleId {
    const build_config = self.build_config_store.buildConfig(config_id);

    var seen: std.AutoHashMapUnmanaged(
        std.Build.Configuration.Module.Index,
        ModuleStore.ModuleId,
    ) = .empty;
    defer seen.deinit(self.gpa);

    var queue: std.ArrayList(std.Build.Configuration.Module.Index) = .empty;
    defer queue.deinit(self.gpa);

    const root_module_id = try self.resolveBuildModuleShallow(
        config_id,
        build_module_index,
    ) orelse return null;

    try seen.put(self.gpa, build_module_index, root_module_id);
    try queue.append(self.gpa, build_module_index);

    while (queue.pop()) |current_build_module_index| {
        const current_module_id = seen.get(current_build_module_index).?;

        // This exact build module may already have been populated by an earlier compile step.
        if (self.module_store.namedImports(current_module_id).count() != 0) {
            continue;
        }

        const build_module = current_build_module_index.get(build_config);

        const imports = build_module.import_table.get(build_config).imports.mal;
        var named_imports: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;
        errdefer {
            var it = named_imports.keyIterator();
            while (it.next()) |key| self.gpa.free(key.*);
            named_imports.deinit(self.gpa);
        }

        try named_imports.ensureTotalCapacity(self.gpa, @intCast(imports.len));
        for (imports.items(.name), imports.items(.module)) |
            build_import_name_id,
            build_import_module_index,
        | {
            const import_name_slice = build_import_name_id.slice(build_config);

            const import_module_id = seen.get(build_import_module_index) orelse child: {
                const resolved = (try self.resolveBuildModuleShallow(
                    config_id,
                    build_import_module_index,
                )) orelse continue;

                try seen.put(self.gpa, build_import_module_index, resolved);
                try queue.append(self.gpa, build_import_module_index);

                break :child resolved;
            };

            named_imports.putAssumeCapacity(
                try self.gpa.dupe(u8, import_name_slice),
                import_module_id,
            );
        }

        self.module_store.modules.items(.named_imports)[current_module_id.toIndex()] = named_imports;
        named_imports = .empty;
    }

    return root_module_id;
}

/// Resolves everything except its descendents (e.g., named imports)
fn resolveBuildModuleShallow(
    self: *LintContext2,
    config_id: BuildConfigStore.ConfigId,
    build_module_index: std.Build.Configuration.Module.Index,
) !?ModuleStore.ModuleId {
    const build_root_path = self.build_config_store.buildRootPath(config_id);
    const build_config = self.build_config_store.buildConfig(config_id);

    const build_module = build_module_index.get(build_config);
    const root_source_file_id = build_module.root_source_file.unwrap() orelse return null;
    const root_source_file = root_source_file_id.get(build_config);
    const root_path = try files.resolveLazyPath(
        root_source_file,
        build_config,
        self.gpa,
        build_root_path,
    ) orelse return null;
    defer self.gpa.free(root_path);

    return try self.module_store.resolve(self.gpa, .{
        .root_file = try self.file_store.resolve(
            root_path,
            self.io,
            self.gpa,
            self.cwd,
        ),
        .build_config = config_id,
        .build_config_module = build_module_index,
        .named_imports = .empty,
    });
}

pub fn deinit(self: *LintContext2) void {
    self.build_config_store.deinit(self.gpa);
    self.file_store.deinit(self.gpa);
    self.compile_contexts.deinit(self.gpa);
    self.module_store.deinit(self.gpa);
    self.decl_store.deinit(self.gpa);
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

const std = @import("std");
const files = @import("../files.zig");
const BuildConfigStore = @import("BuildConfigStore.zig");
const FileStore = @import("FileStore.zig");
const ModuleStore = @import("ModuleStore.zig");
const CompileContext = @import("CompileContext.zig");
const DeclStore = @import("DeclStore.zig");
const tracy = @import("tracy");
