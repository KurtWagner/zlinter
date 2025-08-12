const DefaultFormatter = @This();

formatter: Formatter = .{
    .formatFn = &format,
},

fn format(formatter: *const Formatter, input: Formatter.FormatInput, writer: anytype) Formatter.Error!void {
    const self: *const DefaultFormatter = @alignCast(@fieldParentPtr("formatter", formatter));
    _ = self;

    var error_count: u32 = 0;
    var warning_count: u32 = 0;
    var total_disabled_by_comment: usize = 0;

    var file_arena = std.heap.ArenaAllocator.init(input.arena);

    for (input.results) |file_result| {
        defer _ = file_arena.reset(.retain_capacity);

        var file = input.dir.openFile(
            file_result.file_path,
            .{ .mode = .read_only },
        ) catch |e| return logAndReturnWriteFailure("Open file", e);

        const file_renderer = zlinter.rendering.LintFileRenderer.init(
            file_arena.allocator(),
            file.deprecatedReader(),
        ) catch |e| return logAndReturnWriteFailure("Render", e);

        for (file_result.problems) |problem| {
            if (problem.disabled_by_comment) {
                total_disabled_by_comment += 1;
                continue;
            }

            switch (problem.severity) {
                .off => continue,
                .@"error" => error_count += 1,
                .warning => warning_count += 1,
            }

            var severity_buffer: [32]u8 = undefined;
            writer.print("{s} {s} [{s}{s}:{d}:{d}{s}] {s}{s}{s}\n\n", .{
                problem.severity.name(&severity_buffer, .{ .tty = input.tty }),

                problem.message,

                input.tty.ansiOrEmpty(&.{.underline}),
                file_result.file_path,
                // "+ 1" because line and column are zero indexed but
                // when printing a link to a file it starts at 1.
                problem.start.line + 1,
                problem.start.column + 1,
                input.tty.ansiOrEmpty(&.{.reset}),

                input.tty.ansiOrEmpty(&.{.gray}),
                problem.rule_id,
                input.tty.ansiOrEmpty(&.{.reset}),
            }) catch |e| return logAndReturnWriteFailure("Problem title", e);
            file_renderer.render(
                problem.start.line,
                problem.start.column,
                problem.end.line,
                problem.end.column,
                writer,
                input.tty,
            ) catch |e| return logAndReturnWriteFailure("Problem lint", e);
            writer.writeAll("\n\n") catch |e| return logAndReturnWriteFailure("Newline", e);
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
