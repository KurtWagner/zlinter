const LintConfigStore = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Indexes the file so that it can be looked up.
    index: *const fn (
        self: *anyopaque,
        io: std.Io,
        arena: std.mem.Allocator,
        dir_abs_path: []const u8,
        cwd: std.Io.Dir,
    ) error{InvalidLintConfig}!void,

    /// Resolves an indexed configuration for a given file. Index is always
    /// called on a file first.
    lookup: *const fn (
        self: *const anyopaque,
        dir_abs_path: []const u8,
        rule_idx: RuleIndex,
    ) *anyopaque,

    /// Should clear the index / store back to the original state.
    reset: *const fn (self: *anyopaque) void,
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

pub fn reset(self: LintConfigStore) void {
    return self.vtable.reset(self.ptr);
}

test {
    std.testing.refAllDecls(@This());
}

const RuleIndex = @import("../rules.zig").RuleIndex;
const std = @import("std");
