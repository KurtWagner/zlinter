const JsonFormatter = @This();

formatter: Formatter = .{
    .formatFn = &format,
},

fn format(
    formatter: *const Formatter,
    input: Formatter.FormatInput,
    writer: *std.Io.Writer,
) Formatter.Error!void {
    const self: *const JsonFormatter = @alignCast(@fieldParentPtr("formatter", formatter));
    _ = self;

    var jws = std.json.Stringify{
        .writer = writer,
        .options = .{},
    };

    jws.beginArray() catch |e| return logAndReturnWriteFailure("Begin results", e);

    for (input.results, 0..) |result, i| {
        if (hasEarlierFileResult(input.results[0..i], result.file_id)) continue;

        writeFileResult(input, result.file_id, &jws) catch |e|
            return logAndReturnWriteFailure("File result", e);
    }

    jws.endArray() catch |e| return logAndReturnWriteFailure("End results", e);
    writer.writeByte('\n') catch |e| return logAndReturnWriteFailure("Newline", e);
    writer.flush() catch |e| return logAndReturnWriteFailure("Flush", e);
}

fn hasEarlierFileResult(results: []const zlinter.results.LintResult, file_id: FileId) bool {
    for (results) |result|
        if (result.file_id == file_id) return true;
    return false;
}

fn writeFileResult(
    input: Formatter.FormatInput,
    file_id: FileId,
    jws: *std.json.Stringify,
) !void {
    const counts = countFileProblems(input, file_id);

    try jws.beginObject();

    try jws.objectField("filePath");
    try jws.write(input.file_store.fileAbsPath(file_id));

    try jws.objectField("messages");
    try jws.beginArray();
    for (input.results) |result| {
        if (result.file_id != file_id) continue;
        problems: for (result.problems) |problem| {
            if (problem.disabled_by_comment) continue :problems;
            if (@backingInt(problem.severity) < @backingInt(input.min_severity)) continue :problems;
            try writeProblem(input, file_id, problem, jws);
        }
    }
    try jws.endArray();

    try jws.objectField("suppressedMessages");
    try jws.beginArray();
    suppressed_messages: for (input.results) |result| {
        if (result.file_id != file_id) continue :suppressed_messages;
        suppressed_problems: for (result.problems) |problem| {
            if (!problem.disabled_by_comment) continue :suppressed_problems;
            if (@backingInt(problem.severity) < @backingInt(input.min_severity)) continue :suppressed_problems;
            try writeProblem(input, file_id, problem, jws);
        }
    }
    try jws.endArray();

    try jws.objectField("errorCount");
    try jws.write(counts.error_count);

    try jws.objectField("fatalErrorCount");
    try jws.write(counts.fatal_error_count);

    try jws.objectField("warningCount");
    try jws.write(counts.warning_count);

    try jws.objectField("fixableErrorCount");
    try jws.write(counts.fixable_error_count);

    try jws.objectField("fixableWarningCount");
    try jws.write(counts.fixable_warning_count);

    try jws.endObject();
}

fn writeProblem(
    input: Formatter.FormatInput,
    file_id: FileId,
    problem: zlinter.results.LintProblem,
    jws: *std.json.Stringify,
) !void {
    const exclusive_end_byte_offset = problem.end.byte_offset + 1;
    const problem_range = input.file_store.fileRange(
        file_id,
        problem.start.byte_offset,
        exclusive_end_byte_offset,
    );

    try jws.beginObject();

    try jws.objectField("ruleId");
    try jws.write(problem.rule_id);

    try jws.objectField("severity");
    try jws.write(numericSeverity(problem.severity));

    try jws.objectField("message");
    try jws.write(problem.message);

    try jws.objectField("line");
    try jws.write(problem_range.start.line + 1);

    try jws.objectField("column");
    try jws.write(problem_range.start.column + 1);

    try jws.objectField("endLine");
    try jws.write(problem_range.end.line + 1);

    try jws.objectField("endColumn");
    try jws.write(problem_range.end.column + 1);

    if (isFatal(problem)) {
        try jws.objectField("fatal");
        try jws.write(true);
    }

    if (problem.notes) |notes| {
        try jws.objectField("notes");
        try jws.beginArray();
        for (notes) |note| {
            try jws.beginObject();

            try jws.objectField("message");
            try jws.write(note.message);

            try jws.objectField("line");
            try jws.write(note.line + 1);

            try jws.objectField("column");
            try jws.write(note.column + 1);

            try jws.objectField("filePath");
            try jws.write(input.file_store.fileAbsPath(note.file_id));

            try jws.objectField("range");
            try jws.beginArray();
            try jws.write(note.start.byte_offset);
            try jws.write(note.end.byte_offset);
            try jws.endArray();

            try jws.endObject();
        }
        try jws.endArray();
    }

    if (problem.fix) |fix| {
        try jws.objectField("fix");
        try jws.beginObject();

        try jws.objectField("range");
        try jws.beginArray();
        try jws.write(fix.start);
        try jws.write(fix.end);
        try jws.endArray();

        try jws.objectField("text");
        try jws.write(fix.text);

        try jws.endObject();
    }

    try jws.endObject();
}

const Counts = struct {
    error_count: u32 = 0,
    fatal_error_count: u32 = 0,
    warning_count: u32 = 0,
    fixable_error_count: u32 = 0,
    fixable_warning_count: u32 = 0,
};

fn countFileProblems(input: Formatter.FormatInput, file_id: FileId) Counts {
    var counts: Counts = .{};

    results: for (input.results) |result| {
        if (result.file_id != file_id) continue :results;

        problems: for (result.problems) |problem| {
            if (problem.disabled_by_comment) continue :problems;
            if (@backingInt(problem.severity) < @backingInt(input.min_severity)) continue :problems;

            switch (problem.severity) {
                .off => {},
                .@"error" => {
                    counts.error_count += 1;
                    if (isFatal(problem)) counts.fatal_error_count += 1;
                    if (problem.fix != null) counts.fixable_error_count += 1;
                },
                .warning => {
                    counts.warning_count += 1;
                    if (problem.fix != null) counts.fixable_warning_count += 1;
                },
            }
        }
    }

    return counts;
}

fn numericSeverity(severity: zlinter.rules.LintProblemSeverity) u8 {
    return switch (severity) {
        .off => 0,
        .warning => 1,
        .@"error" => 2,
    };
}

fn isFatal(problem: zlinter.results.LintProblem) bool {
    return std.mem.eql(u8, problem.rule_id, "syntax_error");
}

fn logAndReturnWriteFailure(comptime suffix: []const u8, err: anyerror) error{WriteFailure} {
    std.log.err("Failed to write JSON formatter output (" ++ suffix ++ "): {t}", .{err});
    return error.WriteFailure;
}

test "formats linter JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try testing.writeFile(
        tmp_dir.dir,
        "sample.zig",
        "const bad = 1;\n",
    );

    var session = testing.initFakeContext(arena.allocator(), std.testing.io);

    var abs_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_path = abs_path_buffer[0..try tmp_dir.dir.realPathFile(
        std.testing.io,
        "sample.zig",
        &abs_path_buffer,
    )];
    const file_id = try session.file_store.resolve(abs_path);

    const problems = try arena.allocator().alloc(zlinter.results.LintProblem, 2);
    problems[0] = .{
        .rule_id = "sample_rule",
        .severity = .warning,
        .start = .{ .byte_offset = 6 },
        .end = .{ .byte_offset = 8 },
        .message = "Sample warning",
        .fix = .{
            .start = 6,
            .end = 9,
            .text = "good",
        },
    };
    problems[1] = .{
        .rule_id = "sample_rule",
        .severity = .@"error",
        .start = .{ .byte_offset = 0 },
        .end = .{ .byte_offset = 4 },
        .message = "Suppressed error",
        .disabled_by_comment = true,
    };

    const results = try arena.allocator().alloc(zlinter.results.LintResult, 1);
    results[0] = .{
        .file_id = file_id,
        .problems = problems,
    };

    const formatter_instance = JsonFormatter{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try formatter_instance.formatter.format(.{
        .results = results,
        .file_store = &session.file_store,
        .runtime = session.runtime,
    }, &output.writer);

    const expected = try arena.allocator().print(
        "[{{\"filePath\":\"{s}\",\"messages\":[{{\"ruleId\":\"sample_rule\",\"severity\":1,\"message\":\"Sample warning\",\"line\":1,\"column\":7,\"endLine\":1,\"endColumn\":10,\"fix\":{{\"range\":[6,9],\"text\":\"good\"}}}}],\"suppressedMessages\":[{{\"ruleId\":\"sample_rule\",\"severity\":2,\"message\":\"Suppressed error\",\"line\":1,\"column\":1,\"endLine\":1,\"endColumn\":6}}],\"errorCount\":0,\"fatalErrorCount\":0,\"warningCount\":1,\"fixableErrorCount\":0,\"fixableWarningCount\":1}}]\n",
        .{abs_path},
    );
    try std.testing.expectEqualStrings(expected, output.written());
}

const std = @import("std");
const testing = @import("../testing.zig");
const zlinter = @import("../zlinter.zig");
const FileId = zlinter.session.FileStore.FileId;
const Formatter = @import("Formatter.zig");
