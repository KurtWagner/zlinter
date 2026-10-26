const ZonFormatter = @This();

formatter: Formatter = .{
    .formatFn = &format,
},

fn format(
    formatter: *const Formatter,
    input: Formatter.FormatInput,
    writer: *std.Io.Writer,
) Formatter.Error!void {
    _ = formatter;

    var serializer: std.zon.Serializer = .{
        .writer = writer,
        .options = .{ .whitespace = false },
    };

    writeOutput(input, &serializer) catch |e|
        return logAndReturnWriteFailure("Output", e);

    writer.writeByte('\n') catch |e|
        return logAndReturnWriteFailure("Newline", e);
    writer.flush() catch |e|
        return logAndReturnWriteFailure("Flush", e);
}

fn writeOutput(
    input: Formatter.FormatInput,
    serializer: *std.zon.Serializer,
) std.Io.Writer.Error!void {
    var root = try serializer.beginStruct(.{});
    try root.field("status", @tagName(input.status), .{});
    var results = try root.beginTupleField("results", .{});

    for (input.results, 0..) |result, i| {
        if (common.hasEarlierFileResult(input.results[0..i], result.file_id))
            continue;

        try writeFileResult(input, result.file_id, &results);
    }

    try results.end();
    try root.end();
}

fn writeFileResult(
    input: Formatter.FormatInput,
    file_id: FileId,
    results: *std.zon.Serializer.Tuple,
) std.Io.Writer.Error!void {
    var file = try results.beginStructField(.{});
    try file.field(
        "file_path",
        input.file_store.fileAbsPath(file_id),
        .{},
    );

    var counts: common.Counts = .{};
    var messages = try file.beginTupleField("messages", .{});
    for (input.results) |result| {
        if (result.file_id != file_id) continue;
        problems: for (result.problems) |problem| {
            if (problem.disabled_by_comment or !common.isVisible(input, problem))
                continue :problems;

            counts.add(problem);

            try writeProblem(
                input,
                file_id,
                problem,
                &messages,
            );
        }
    }
    try messages.end();

    var suppressed_messages = try file.beginTupleField(
        "suppressed_messages",
        .{},
    );
    for (input.results) |result| {
        if (result.file_id != file_id) continue;

        problems: for (result.problems) |problem| {
            if (!problem.disabled_by_comment or !common.isVisible(input, problem))
                continue :problems;

            try writeProblem(
                input,
                file_id,
                problem,
                &suppressed_messages,
            );
        }
    }
    try suppressed_messages.end();

    try file.field("error_count", counts.error_count, .{});
    try file.field("fatal_error_count", counts.fatal_error_count, .{});
    try file.field("warning_count", counts.warning_count, .{});
    try file.field("fixable_error_count", counts.fixable_error_count, .{});
    try file.field("fixable_warning_count", counts.fixable_warning_count, .{});
    try file.end();
}

fn writeProblem(
    input: Formatter.FormatInput,
    file_id: FileId,
    problem: zlinter.results.LintProblem,
    messages: *std.zon.Serializer.Tuple,
) std.Io.Writer.Error!void {
    const problem_range = input.file_store.fileRange(
        file_id,
        problem.start.byte_offset,
        problem.end.byte_offset + 1,
    );

    var message = try messages.beginStructField(.{});
    try message.field("rule_id", problem.rule_id, .{});
    try message.field("severity", common.numericSeverity(problem.severity), .{});
    try message.field("message", problem.message, .{});
    try message.field("line", problem_range.start.line + 1, .{});
    try message.field("column", problem_range.start.column + 1, .{});
    try message.field("end_line", problem_range.end.line + 1, .{});
    try message.field("end_column", problem_range.end.column + 1, .{});

    const fatal = common.isFatal(problem);
    if (fatal) try message.field("fatal", fatal, .{});

    if (problem.notes) |notes| {
        var output_notes = try message.beginTupleField("notes", .{});
        for (notes) |note| {
            var output_note = try output_notes.beginStructField(.{});
            try output_note.field("message", note.message, .{});
            try output_note.field("line", note.line + 1, .{});
            try output_note.field("column", note.column + 1, .{});
            try output_note.field("file_path", input.file_store.fileAbsPath(note.file_id), .{});
            try output_note.field("range", [2]usize{ note.start.byte_offset, note.end.byte_offset }, .{});
            try output_note.end();
        }
        try output_notes.end();
    }

    if (problem.fix) |fix| {
        var output_fix = try message.beginStructField("fix", .{});
        try output_fix.field("range", [2]usize{ fix.start, fix.end }, .{});
        try output_fix.field("text", fix.text, .{});
        try output_fix.end();
    }

    try message.end();
}

fn logAndReturnWriteFailure(comptime suffix: []const u8, err: anyerror) error{WriteFailure} {
    std.log.err("Failed to write ZON formatter output (" ++ suffix ++ "): {t}", .{err});
    return error.WriteFailure;
}

test "formats successful empty ZON result" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var session = @import("../testing.zig").initFakeContext(arena.allocator(), std.testing.io);

    const formatter_instance = ZonFormatter{};
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try formatter_instance.formatter.format(.{
        .results = &.{},
        .file_store = &session.file_store,
        .runtime = session.runtime,
    }, &output.writer);

    try std.testing.expectEqualStrings(
        \\.{.status="success",.results=.{}}
        \\
    , output.written());
}

const common = @import("common.zig");
const Formatter = @import("Formatter.zig");
const std = @import("std");
const zlinter = @import("../zlinter.zig");
const FileId = zlinter.session.FileStore.FileId;
