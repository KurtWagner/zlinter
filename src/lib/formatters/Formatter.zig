const Formatter = @This();

pub const FormatInput = struct {
    results: []zlinter.results.LintResult,
    /// The directory the linter ran relative to.
    dir: std.fs.Dir,
    /// Arena allocator that is cleared after calling format.
    arena: std.mem.Allocator,

    io: std.Io,
    tty: zlinter.ansi.Tty = .no_color,

    /// Only print this severity and above. e.g., set to error to only format errors
    min_severity: zlinter.rules.LintProblemSeverity = .warning,
};

pub const Error = error{
    OutOfMemory,
    WriteFailure,
};

formatFn: *const fn (*const Formatter, FormatInput, writer: *std.Io.Writer) Error!void,

pub inline fn format(self: *const Formatter, input: FormatInput, writer: *std.Io.Writer) Error!void {
    return self.formatFn(self, input, writer);
}

const std = @import("std");
const zlinter = @import("../zlinter.zig");
