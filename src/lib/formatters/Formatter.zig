const Formatter = @This();

pub const FormatInput = struct {
    results: []zlinter.results.LintResult,
    file_store: *const zlinter.session.FileStore,
    runtime: *const zlinter.session.LintRuntime,
    tty: zlinter.ansi.Tty = .no_color,

    /// Only print this severity and above. e.g., set to error to only format errors
    min_severity: zlinter.rules.LintProblemSeverity = .warning,
};

pub const Error = error{
    WriteFailure,
};

formatFn: *const fn (*const Formatter, FormatInput, writer: *std.Io.Writer) Error!void,

pub inline fn format(self: *const Formatter, input: FormatInput, writer: *std.Io.Writer) Error!void {
    return self.formatFn(self, input, writer);
}

const std = @import("std");
const zlinter = @import("../zlinter.zig");

test {
    std.testing.refAllDecls(@This());
}
