pub const Counts = struct {
    error_count: u32 = 0,
    fatal_error_count: u32 = 0,
    warning_count: u32 = 0,
    fixable_error_count: u32 = 0,
    fixable_warning_count: u32 = 0,

    pub fn add(self: *Counts, problem: zlinter.results.LintProblem) void {
        switch (problem.severity) {
            .off => {},
            .@"error" => {
                self.error_count += 1;
                if (isFatal(problem)) self.fatal_error_count += 1;
                if (problem.fix != null) self.fixable_error_count += 1;
            },
            .warning => {
                self.warning_count += 1;
                if (problem.fix != null) self.fixable_warning_count += 1;
            },
        }
    }
};

pub fn hasEarlierFileResult(results: []const zlinter.results.LintResult, file_id: FileId) bool {
    for (results) |result|
        if (result.file_id == file_id) return true;
    return false;
}

pub fn isVisible(input: Formatter.FormatInput, problem: zlinter.results.LintProblem) bool {
    return @backingInt(problem.severity) >= @backingInt(input.min_severity);
}

pub fn numericSeverity(severity: zlinter.rules.LintProblemSeverity) u8 {
    return switch (severity) {
        .off => 0,
        .warning => 1,
        .@"error" => 2,
    };
}

pub fn isFatal(problem: zlinter.results.LintProblem) bool {
    return std.mem.eql(u8, problem.rule_id, "syntax_error");
}

const Formatter = @import("Formatter.zig");
const std = @import("std");
const zlinter = @import("../zlinter.zig");
const FileId = zlinter.session.FileStore.FileId;
