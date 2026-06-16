const ModuleStore = @This();

modules: std.MultiArrayList(ModuleEntry),
module_key_to_module_id: std.HashMapUnmanaged(
    ModuleKey,
    ModuleId,
    ModuleKeyContext,
    std.hash_map.default_max_load_percentage,
),

pub const ModuleEntry = struct {
    root_file: FileId,

    /// Key owned imports configured by the build/module system (e.g., `@import("foo")`)
    named_imports: std.StringHashMapUnmanaged(ModuleId),
};

const ModuleKeyContext = struct {
    pub fn eql(self: ModuleKeyContext, a: ModuleKey, b: ModuleKey) bool {
        _ = self;
        return a.eql(b);
    }

    pub fn hash(self: ModuleKeyContext, key: ModuleKey) u64 {
        _ = self;
        return key.hash();
    }
};

pub const ModuleKey = struct {
    root_file: FileId,
    build_config: BuildConfigStore.ConfigId,
    build_config_module: std.Build.Configuration.Module.Index,

    fn init(seed: ModuleSeed) ModuleKey {
        return .{
            .root_file = seed.root_file,
            .build_config = seed.build_config,
            .build_config_module = seed.build_config_module,
        };
    }

    pub fn eql(self: ModuleKey, other: ModuleKey) bool {
        return self.root_file == other.root_file and
            self.build_config == other.build_config and
            self.build_config_module == other.build_config_module;
    }

    pub fn hash(self: ModuleKey) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, self.root_file.toIndex());
        std.hash.autoHash(&wy, self.build_config.toIndex());
        std.hash.autoHash(&wy, @intFromEnum(self.build_config_module));
        return wy.final();
    }
};

pub const ModuleId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) ModuleId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: ModuleId) usize {
        return @intFromEnum(self);
    }
};

pub const ModuleSeed = struct {
    root_file: FileId,
    build_config: BuildConfigStore.ConfigId,
    build_config_module: std.Build.Configuration.Module.Index,

    /// Key owned imports configured by the build/module system (e.g., `@import("foo")`)
    named_imports: std.StringHashMapUnmanaged(ModuleId),
};

pub const empty: ModuleStore = .{
    .modules = .empty,
    .module_key_to_module_id = .empty,
};

pub fn deinit(self: *ModuleStore, gpa: std.mem.Allocator) void {
    for (self.modules.items(.named_imports)) |*named_imports| {
        var it = named_imports.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        named_imports.deinit(gpa);
    }
    self.modules.deinit(gpa);
    self.module_key_to_module_id.deinit(gpa);
}

pub fn resolve(self: *ModuleStore, gpa: std.mem.Allocator, seed: ModuleSeed) !ModuleId {
    const zone = tracy.traceNamed(@src(), "ModuleStore.resolve");
    defer zone.end();

    const key: ModuleKey = .init(seed);
    if (self.module_key_to_module_id.get(key)) |id|
        return id;

    const id: ModuleId = .fromIndex(self.modules.len);
    try self.modules.append(gpa, .{
        .root_file = seed.root_file,
        .named_imports = seed.named_imports,
    });
    errdefer _ = self.modules.swapRemove(id.toIndex());

    try self.module_key_to_module_id.put(gpa, key, id);
    errdefer _ = self.module_key_to_module_id.remove(key);

    return id;
}

pub fn rootFile(self: *const ModuleStore, module_id: ModuleId) FileId {
    return self.modules.items(.root_file)[module_id.toIndex()];
}

pub fn moduleForRootFile(self: *const ModuleStore, file_id: FileId) ?ModuleId {
    for (self.modules.items(.root_file), 0..) |root_file, index| {
        if (root_file == file_id) return .fromIndex(index);
    }
    return null;
}

pub fn namedImports(
    self: *const ModuleStore,
    module_id: ModuleId,
) *const std.StringHashMapUnmanaged(ModuleId) {
    return &self.modules.items(.named_imports)[module_id.toIndex()];
}

pub fn namedImport(
    self: *const ModuleStore,
    module_id: ModuleId,
    name: []const u8,
) ?ModuleId {
    return self.namedImports(module_id).get(name);
}

const FileId = @import("FileStore.zig").FileId;
const BuildConfigStore = @import("BuildConfigStore.zig");
const std = @import("std");
const tracy = @import("tracy");
