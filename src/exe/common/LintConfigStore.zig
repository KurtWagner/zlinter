const LintConfigStore = @This();

pub const LintConfigId = u32;

base_config_id: LintConfigId,
configs: std.ArrayList(LintConfig),
config_by_dir_abs_path: std.StringHashMapUnmanaged(?LintConfigId),

pub fn init(arena: std.mem.Allocator, base_rule_configs: [lint_builtin.rules.len]*anyopaque) LintConfigStore {
    var self: LintConfigStore = .{
        .configs = .empty,
        .config_by_dir_abs_path = .empty,
        .base_config_id = 0,
    };

    self.configs.append(arena, .{
        .rule_configs = base_rule_configs,
        .rule_configs_on = .full,
    }) catch @panic("OOM");

    return self;
}

pub fn index(
    self: *LintConfigStore,
    io: std.Io,
    arena: std.mem.Allocator,
    dir_abs_path: []const u8,
    cwd: std.Io.Dir,
) error{InvalidLintConfig}!void {
    std.debug.assert(std.Io.Dir.path.isAbsolute(dir_abs_path));

    const normalized_slice = std.mem.trimEnd(
        u8,
        dir_abs_path,
        std.Io.Dir.path.sep_str,
    );
    if (normalized_slice.len == 0) return;

    // We only make a copy for key indexing if we need to index part of the
    // path, in which case we make a copy of it and base all slices keys
    // off it in memory stored in the arena.
    var maybe_normalized_copy: ?[]const u8 = null;

    for (normalized_slice, 0..) |c, i| {
        if (!std.Io.Dir.path.isSep(c)) continue;

        if (self.needsIndexing(normalized_slice[0..i])) {
            if (maybe_normalized_copy == null)
                maybe_normalized_copy = arena.dupe(u8, normalized_slice) catch @panic("OOM");
            try self.insertIntoIndex(
                io,
                arena,
                maybe_normalized_copy.?[0..i],
                cwd,
            );
        }
    }
    if (self.needsIndexing(normalized_slice[0..])) {
        if (maybe_normalized_copy == null)
            maybe_normalized_copy = arena.dupe(u8, normalized_slice) catch @panic("OOM");
        try self.insertIntoIndex(
            io,
            arena,
            maybe_normalized_copy.?[0..],
            cwd,
        );
    }
}

/// Returns true if `insertIntoIndex` needs to be called for a path.
fn needsIndexing(
    self: *const LintConfigStore,
    dir_abs_sub_path: []const u8,
) bool {
    return dir_abs_sub_path.len > 0 and
        !self.config_by_dir_abs_path.contains(dir_abs_sub_path);
}

/// Inserts a path into the index, should check `needsIndexing` before
/// calling this.
fn insertIntoIndex(
    self: *LintConfigStore,
    io: std.Io,
    arena: std.mem.Allocator,
    dir_abs_sub_path: []const u8,
    cwd: std.Io.Dir,
) error{InvalidLintConfig}!void {
    std.debug.assert(self.needsIndexing(dir_abs_sub_path));

    std.log.info("Index zlinter config: '{s}'", .{dir_abs_sub_path});
    if (try LintConfig.tryLoad(
        io,
        arena,
        cwd,
        dir_abs_sub_path,
    )) |config| {
        const config_id: LintConfigId = @intCast(self.configs.items.len);
        self.configs.append(arena, config) catch @panic("OOM");
        self
            .config_by_dir_abs_path
            .putNoClobber(
            arena,
            dir_abs_sub_path,
            config_id,
        ) catch @panic("OOM");
    } else {
        self
            .config_by_dir_abs_path
            .putNoClobber(
            arena,
            dir_abs_sub_path,
            null,
        ) catch @panic("OOM");
    }
}

pub fn lookup(self: *const LintConfigStore, dir_abs_path: []const u8, rule_idx: RuleIndex) *anyopaque {
    std.debug.assert(std.Io.Dir.path.isAbsolute(dir_abs_path));
    std.debug.assert(dir_abs_path.len > 0);

    const normalized = std.mem.trimEnd(
        u8,
        dir_abs_path,
        std.Io.Dir.path.sep_str,
    );
    std.debug.assert(normalized.len > 0);

    if (self.configByDir(normalized)) |config| {
        const lint_config = self.configs.items[config];
        if (lint_config.rule_configs_on.isSet(@intFromEnum(rule_idx)))
            return lint_config.rule_configs[@intFromEnum(rule_idx)];
    }

    var rhs = normalized.len;
    while (rhs > 0) : (rhs -= 1)
        if (std.Io.Dir.path.isSep(normalized[rhs - 1])) {
            const parent_dir = normalized[0 .. rhs - 1];
            if (self.configByDir(parent_dir)) |config| {
                const lint_config = self.configs.items[config];
                if (lint_config.rule_configs_on.isSet(@intFromEnum(rule_idx)))
                    return lint_config.rule_configs[@intFromEnum(rule_idx)];
            }
        };
    std.log.info("No zlinter.zon for {s}", .{dir_abs_path});
    return self.configs.items[self.base_config_id].rule_configs[@intFromEnum(rule_idx)];
}

pub fn getConfig(self: *const LintConfigStore, config_id: LintConfigId, rule_idx: RuleIndex) *anyopaque {
    return self.configs.items[config_id].rule_configs[@intFromEnum(rule_idx)];
}

fn configByDir(self: *const LintConfigStore, dir_abs_path: []const u8) ?LintConfigId {
    return self.config_by_dir_abs_path.get(dir_abs_path) orelse null;
}

const LintConfig = struct {
    const max_config_size_bytes = 10 * 1025;

    rule_configs: [lint_builtin.rules.len]*anyopaque,
    rule_configs_on: std.bit_set.Static(lint_builtin.rules.len),

    /// What users write in nested directories to overwrite specific rule configs.
    const Zon = struct {
        rules: RulesConfig,
    };

    pub const empty: LintConfig = .{
        .rule_configs = undefined,
        .rule_configs_on = .empty,
    };

    pub fn tryLoad(
        io: std.Io,
        arena: std.mem.Allocator,
        cwd: std.Io.Dir,
        dir_abs_path: []const u8,
    ) error{InvalidLintConfig}!?LintConfig {
        var fba_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var fba_path: std.heap.FixedBufferAllocator = .init(&fba_path_buffer);

        const lint_config_abs_path = std.Io.Dir.path.resolve(
            fba_path.allocator(),
            &.{ dir_abs_path, "zlinter.zon" },
        ) catch unreachable;

        std.log.info("Looking for: '{s}'", .{lint_config_abs_path});

        var fba_config_buffer: [max_config_size_bytes]u8 = undefined;
        var fba_config: std.heap.FixedBufferAllocator = .init(&fba_config_buffer);

        const source = cwd.readFileAllocOptions(
            io,
            lint_config_abs_path,
            fba_config.allocator(),
            .limited(max_config_size_bytes),
            .of(u8),
            0,
        ) catch |e| switch (e) {
            error.FileNotFound => {
                return null;
            },
            else => {
                std.log.err(
                    "Could not read lint config '{s}' due to: {t}",
                    .{ lint_config_abs_path, e },
                );
                return error.InvalidLintConfig;
            },
        };

        @setEvalBranchQuota(5000);
        var diagnostics: std.zon.parse.Diagnostics = .{};
        const zon = arena.create(Zon) catch @panic("OOM");
        zon.* = std.zon.parse.fromSliceAlloc(
            Zon,
            arena,
            source,
            &diagnostics,
            .{},
        ) catch |e| {
            if (e == error.OutOfMemory) @panic("OOM");
            std.log.err(
                "Failed to parse lint config: '{s}' due to {t} - {f}",
                .{ lint_config_abs_path, e, diagnostics },
            );
            return error.InvalidLintConfig;
        };

        var self: LintConfig = .empty;
        inline for (0..lint_builtin.rules.len) |i|
            if (@field(zon.rules, lint_builtin.rule_names[i])) |*v| {
                self.rule_configs[i] = @ptrCast(@alignCast(v));
                self.rule_configs_on.set(i);
            };

        return self;
    }
};

test "LintConfigStore.index errors on malformed zlinter.zon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "nested");
    try zlinter.testing.writeFile(
        tmp_dir.dir,
        "nested/zlinter.zon",
        ".{ .rules = .{ .no_unused = ",
    );

    var dir_abs_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_abs_path = dir_abs_path_buffer[0..try tmp_dir.dir.realPath(
        std.testing.io,
        "nested",
        &dir_abs_path_buffer,
    )];

    var store = LintConfigStore.init(
        arena.allocator(),
        lint_builtin.rule_configs,
    );
    try std.testing.expectError(
        error.InvalidLintConfig,
        store.index(
            std.testing.io,
            arena.allocator(),
            dir_abs_path,
            std.Io.Dir.cwd(),
        ),
    );
}

test "LintConfigStore.index errors when zlinter.zon is not readable as a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(
        std.testing.io,
        "nested/zlinter.zon",
    );

    var dir_abs_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_abs_path = dir_abs_path_buffer[0..try tmp_dir.dir.realPath(
        std.testing.io,
        "nested",
        &dir_abs_path_buffer,
    )];

    var store = LintConfigStore.init(
        arena.allocator(),
        lint_builtin.rule_configs,
    );
    try std.testing.expectError(
        error.InvalidLintConfig,
        store.index(
            std.testing.io,
            arena.allocator(),
            dir_abs_path,
            std.Io.Dir.cwd(),
        ),
    );
}

test {
    std.testing.refAllDecls(@This());
}

const lint_builtin = @import("lint_builtin");
const std = @import("std");
const zlinter = @import("zlinter");

const RulesConfig = lint_builtin.RulesConfig;
const RuleIndex = zlinter.rules.RuleIndex;
