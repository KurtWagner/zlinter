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
session_arena: std.mem.Allocator,

const std = @import("std");
