const ModuleStore = @This();

modules: std.ArrayList(ModuleEntry),
module_key_to_module_id: std.HashMapUnmanaged(
    ModuleKey,
    ModuleId,
    ModuleKeyContext,
    std.hash_map.default_max_load_percentage,
),

pub const ModuleEntry = struct {
    id: ModuleId,
    root_file: FileId,

    /// Imports configured by the build/module system.
    ///
    /// These:
    ///   @import("foo")
    ///   @import("zlinter")
    ///
    /// Not these:
    ///   @import("./relative.zig")
    ///   @import("../x.zig")
    named_imports: std.StringHashMapUnmanaged(ModuleId),
};

const ModuleKeyContext = struct {
    pub fn eql(self: ModuleKeyContext, a: ModuleKey, b: ModuleKey) bool {
        _ = self;
        return a.root_file == b.root_file;
    }

    pub fn hash(self: ModuleKeyContext, key: ModuleKey) u64 {
        _ = self;
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, key.root_file.toIndex());
        return wy.final();
    }
};

pub const ModuleKey = struct {
    root_file: FileId,
    // TODO: #149 - THis needs more stuff, file id isn't a good key alone

    fn init(seed: ModuleSeed) ModuleKey {
        return .{
            .root_file = seed.root_file,
        };
    }

    pub fn eql(self: ModuleKey, other: ModuleKey) bool {
        return self.root_file == other.root_file;
    }

    pub fn hash(self: ModuleKey) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, self.root_file.toIndex());
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

    /// Imports configured by the build/module system (e.g., `@import("foo")`)
    named_imports: std.StringHashMapUnmanaged(ModuleId),
};

pub const empty: ModuleStore = .{
    .modules = .empty,
    .module_key_to_module_id = .empty,
};

pub fn deinit(self: *ModuleStore, gpa: std.mem.Allocator) void {
    for (self.modules.items) |*module| {
        module.named_imports.deinit(gpa);
    }
    self.modules.deinit(gpa);
    self.module_key_to_module_id.deinit(gpa);
}

pub fn resolve(self: *ModuleStore, gpa: std.mem.Allocator, seed: ModuleSeed) !ModuleId {
    const key: ModuleKey = .init(seed);
    var seed_named_imports = seed.named_imports;
    if (self.module_key_to_module_id.get(key)) |id| {
        const existing = &self.modules.items[id.toIndex()];
        if (existing.named_imports.count() == 0 and seed_named_imports.count() != 0) {
            existing.named_imports.deinit(gpa);
            existing.named_imports = seed_named_imports;
        } else {
            seed_named_imports.deinit(gpa);
        }
        return id;
    }

    const id: ModuleId = .fromIndex(self.modules.items.len);
    try self.modules.append(gpa, .{
        .id = id,
        .root_file = seed.root_file,
        .named_imports = seed_named_imports,
    });
    errdefer _ = self.modules.swapRemove(id.toIndex());

    try self.module_key_to_module_id.put(gpa, key, id);
    errdefer _ = self.module_key_to_module_id.remove(key);

    return id;
}

const FileId = @import("FileStore.zig").FileId;
const std = @import("std");
