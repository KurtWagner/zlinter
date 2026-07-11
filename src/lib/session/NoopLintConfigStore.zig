const NoopLintConfigStore = @This();

pub const init: NoopLintConfigStore = .{};

pub fn store(self: *NoopLintConfigStore) LintConfigStore {
    return .{
        .ptr = self,
        .vtable = &vtable,
    };
}

const vtable: LintConfigStore.VTable = .{
    .index = index,
    .lookup = lookup,
    .reset = reset,
};

fn index(
    ptr: *anyopaque,
    io: std.Io,
    arena: std.mem.Allocator,
    dir_abs_path: []const u8,
    cwd: std.Io.Dir,
) error{InvalidLintConfig}!void {
    _ = ptr;
    _ = io;
    _ = arena;
    _ = dir_abs_path;
    _ = cwd;
}

fn lookup(
    ptr: *const anyopaque,
    dir_abs_path: []const u8,
    rule_idx: RuleIndex,
) *anyopaque {
    _ = ptr;
    _ = dir_abs_path;
    _ = rule_idx;
    @panic("Noop, nothing to lookup");
}

fn reset(ptr: *anyopaque) void {
    _ = ptr;
}

test {
    std.testing.refAllDecls(@This());
}

const RuleIndex = @import("../rules.zig").RuleIndex;
const std = @import("std");
const LintConfigStore = @import("LintConfigStore.zig");
