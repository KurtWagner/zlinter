const LintConfigStore = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    index: *const fn (
        self: *anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        dir_abs_path: []const u8,
        cwd: std.Io.Dir,
    ) error{InvalidLintConfig}!void,

    lookup: *const fn (
        self: *const anyopaque,
        dir_abs_path: []const u8,
        rule_idx: RuleIndex,
    ) *anyopaque,
};

pub fn index(
    self: LintConfigStore,
    io: std.Io,
    arena: std.mem.Allocator,
    dir_abs_path: []const u8,
    cwd: std.Io.Dir,
) error{InvalidLintConfig}!void {
    return self.vtable.index(
        self.ptr,
        io,
        arena,
        dir_abs_path,
        cwd,
    );
}

pub fn lookup(
    self: LintConfigStore,
    dir_abs_path: []const u8,
    rule_idx: RuleIndex,
) *anyopaque {
    return self.vtable.lookup(
        self.ptr,
        dir_abs_path,
        rule_idx,
    );
}

test {
    std.testing.refAllDecls(@This());
}

const RuleIndex = @import("../rules.zig").RuleIndex;
const std = @import("std");
