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

    for (input.results) |file_result| {
        var file = input.dir.openFile(file_result.file_path, .{ .mode = .read_only }) catch return error.WriteFailure;
        const file_renderer = zlinter.LintFileRenderer.init(input.arena, file.reader()) catch return error.WriteFailure;

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
                problem.severity.name(&severity_buffer, .{ .ansi = true }),

                problem.message,

                zlinter.ansi.get(&.{.underline}),
                file_result.file_path,
                // "+ 1" because line and column are zero indexed but
                // when printing a link to a file it starts at 1.
                problem.start.line + 1,
                problem.start.column + 1,
                zlinter.ansi.get(&.{.reset}),

                zlinter.ansi.get(&.{.gray}),
                problem.rule_id,
                zlinter.ansi.get(&.{.reset}),
            }) catch return error.WriteFailure;
            file_renderer.render(
                problem.start.line,
                problem.start.column,
                problem.end.line,
                problem.end.column,
                writer,
            ) catch return error.WriteFailure;
            writer.writeAll("\n\n") catch return error.WriteFailure;
        }
    }

    if (error_count > 0) {
        writer.print("{s}x {d} errors{s}\n", .{
            zlinter.ansi.get(&.{ .red, .bold }),
            error_count,
            zlinter.ansi.get(&.{.reset}),
        }) catch return error.WriteFailure;
    }

    if (warning_count > 0) {
        writer.print("{s}x {d} warnings{s}\n", .{
            zlinter.ansi.get(&.{ .yellow, .bold }),
            warning_count,
            zlinter.ansi.get(&.{.reset}),
        }) catch return error.WriteFailure;
    }

    if (total_disabled_by_comment > 0) {
        writer.print(
            "{s}x {d} skipped{s}\n",
            .{
                zlinter.ansi.get(&.{ .bold, .gray }),
                total_disabled_by_comment,
                zlinter.ansi.get(&.{.reset}),
            },
        ) catch return error.WriteFailure;
    }

    if (warning_count == 0 and error_count == 0) {
        writer.print(
            "{s}No issues!{s}\n",
            .{
                zlinter.ansi.get(&.{ .bold, .green }),
                zlinter.ansi.get(&.{.reset}),
            },
        ) catch return error.WriteFailure;
    }
}

const Formatter = @import("./Formatter.zig");
const zlinter = @import("../zlinter.zig");
