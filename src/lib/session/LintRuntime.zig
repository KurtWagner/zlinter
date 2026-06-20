//! Stores shared runtime references - allocators, io, paths.

const LintRuntime = @This();

io: std.Io,

verbose: bool,

/// Externally owned slice to zig executable path
zig_exe: []const u8,

/// Externally owned slice to zig lib directory path
zig_lib_directory: []const u8,

/// Externally owned slice to current working directory
cwd: []const u8,

/// Lives for the full linter invocation.
session_arena: *std.heap.ArenaAllocator,

/// Lives for the execution of all rules on a single file.
file_arena: *std.heap.ArenaAllocator,

/// Lives for the execution of a single rule run and fix on a file.
rule_arena: *std.heap.ArenaAllocator,

pub fn init(io: std.Io, gpa: std.mem.Allocator, args: Args) LintRuntime {
    const session_arena = oom(gpa.create(std.heap.ArenaAllocator));
    session_arena.* = .init(gpa);

    const file_arena = oom(gpa.create(std.heap.ArenaAllocator));
    file_arena.* = .init(gpa);

    const rule_arena = oom(gpa.create(std.heap.ArenaAllocator));
    rule_arena.* = .init(gpa);

    return .{
        .io = io,
        .verbose = args.verbose,
        .session_arena = session_arena,
        .file_arena = file_arena,
        .rule_arena = rule_arena,
        .zig_exe = args.zig_exe,
        .zig_lib_directory = args.zig_lib_directory,
        .cwd = std.process.currentPathAlloc(
            io,
            session_arena.allocator(),
        ) catch unreachable,
    };
}

pub fn sessionArena(self: *const LintRuntime) std.mem.Allocator {
    return self.session_arena.allocator();
}

pub fn fileArena(self: *const LintRuntime) std.mem.Allocator {
    return self.file_arena.allocator();
}

pub fn ruleArena(self: *const LintRuntime) std.mem.Allocator {
    return self.rule_arena.allocator();
}

pub fn resetFileArena(self: *const LintRuntime) void {
    _ = self.file_arena.reset(.retain_capacity);
}

pub fn resetRuleArena(self: *const LintRuntime) void {
    _ = self.rule_arena.reset(.retain_capacity);
}

pub fn deinit(self: *LintRuntime, gpa: std.mem.Allocator) void {
    self.file_arena.deinit();
    self.session_arena.deinit();
    self.rule_arena.deinit();

    gpa.destroy(self.file_arena);
    gpa.destroy(self.session_arena);
    gpa.destroy(self.rule_arena);
}

const std = @import("std");
const Args = @import("../Args.zig");
const oom = @import("../allocations.zig").oom;
