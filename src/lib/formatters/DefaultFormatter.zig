const DefaultFormatter = @This();

formatter: Formatter = .{
    .formatFn = &format,
},

fn format(formatter: *const Formatter, input: Formatter.FormatInput, writer: *std.Io.Writer) Formatter.Error!void {
    const self: *const DefaultFormatter = @alignCast(@fieldParentPtr("formatter", formatter));
    _ = self;

    var error_count: u32 = 0;
    var warning_count: u32 = 0;
    var total_disabled_by_comment: usize = 0;

    var file_arena = std.heap.ArenaAllocator.init(input.arena);
    var file_buffer: [2048]u8 = undefined;

    for (input.results) |file_result| {
        defer _ = file_arena.reset(.retain_capacity);

        var file = input.dir.openFile(
            file_result.file_path,
            .{ .mode = .read_only },
        ) catch |e| return logAndReturnWriteFailure("Open file", e);

        var file_reader = file.reader(&file_buffer);

        const file_renderer = zlinter.rendering.LintFileRenderer.init(
            file_arena.allocator(),
            &file_reader.interface,
        ) catch |e| return logAndReturnWriteFailure("Render", e);

        for (file_result.problems) |problem| {
            if (@intFromEnum(problem.severity) < @intFromEnum(input.min_severity)) {
                continue;
            }

            if (problem.disabled_by_comment) {
                total_disabled_by_comment += 1;
                continue;
            }

            switch (problem.severity) {
                .off => continue,
                .@"error" => error_count += 1,
                .warning => warning_count += 1,
            }

            const start_line, const start_column = file_renderer.lineAndColumn(problem.start.byte_offset);
            const end_line, const end_column = file_renderer.lineAndColumn(problem.end.byte_offset);

            var severity_buffer: [32]u8 = undefined;
            writer.print("{s} {s} [{s}{s}:{d}:{d}{s}] {s}{s}{s}\n\n", .{
                problem.severity.name(&severity_buffer, .{ .tty = input.tty }),

                problem.message,

                input.tty.ansiOrEmpty(&.{.underline}),
                file_result.file_path,
                // "+ 1" because line and column are zero indexed but
                // when printing a link to a file it starts at 1.
                start_line + 1,
                start_column + 1,
                input.tty.ansiOrEmpty(&.{.reset}),

                input.tty.ansiOrEmpty(&.{.gray}),
                problem.rule_id,
                input.tty.ansiOrEmpty(&.{.reset}),
            }) catch |e| return logAndReturnWriteFailure("Problem title", e);
            file_renderer.render(
                start_line,
                start_column,
                end_line,
                end_column,
                writer,
                input.tty,
            ) catch |e| return logAndReturnWriteFailure("Problem lint", e);
            writer.writeAll("\n\n") catch |e| return logAndReturnWriteFailure("Newline", e);
            writer.flush() catch |e| return logAndReturnWriteFailure("Flush", e);
        }
    }

    if (error_count > 0) {
        writer.print("{s}x {d} errors{s}\n", .{
            input.tty.ansiOrEmpty(&.{ .red, .bold }),
            error_count,
            input.tty.ansiOrEmpty(&.{.reset}),
        }) catch |e| return logAndReturnWriteFailure("Errors", e);
    }

    if (warning_count > 0) {
        writer.print("{s}x {d} warnings{s}\n", .{
            input.tty.ansiOrEmpty(&.{ .yellow, .bold }),
            warning_count,
            input.tty.ansiOrEmpty(&.{.reset}),
        }) catch |e| return logAndReturnWriteFailure("Warnings", e);
    }

    if (total_disabled_by_comment > 0) {
        writer.print(
            "{s}x {d} skipped{s}\n",
            .{
                input.tty.ansiOrEmpty(&.{ .bold, .gray }),
                total_disabled_by_comment,
                input.tty.ansiOrEmpty(&.{.reset}),
            },
        ) catch |e| return logAndReturnWriteFailure("Skipped", e);
    }

    if (warning_count == 0 and error_count == 0) {
        writer.print(
            "{s}No issues!{s}\n",
            .{
                input.tty.ansiOrEmpty(&.{ .bold, .green }),
                input.tty.ansiOrEmpty(&.{.reset}),
            },
        ) catch |e| return logAndReturnWriteFailure("Summary", e);
    }
}

fn logAndReturnWriteFailure(comptime suffix: []const u8, err: anyerror) error{WriteFailure} {
    std.log.err(suffix ++ " failed to write: {s}", .{@errorName(err)});
    return error.WriteFailure;
}

const Formatter = @import("./Formatter.zig");
const std = @import("std");
const zlinter = @import("../zlinter.zig");
