const Formatter = @This();

pub const FormatInput = struct {
    results: []zlinter.results.LintResult,
    /// The directory the linter ran relative to.
    dir: std.fs.Dir,
    /// Arena allocator that is cleared after calling format.
    arena: std.mem.Allocator,
};

pub const Error = error{
    OutOfMemory,
    WriteFailure,
};

formatFn: *const fn (*const Formatter, FormatInput, writer: anytype) Error!void,

pub inline fn format(self: *const Formatter, input: FormatInput, writer: anytype) Error!void {
    return self.formatFn(self, input, writer);
}

const zlinter = @import("../zlinter.zig");
const std = @import("std");
