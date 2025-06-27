const std = @import("std");

const MAX_FILE_SIZE_BYTES = 10 * 1024 * 1024;
const INPUT_SUFFIX = ".input.zig";
const LINT_OUTPUT_SUFFIX = ".lint_expected.stdout";
const FIX_ZIG_OUTPUT_SUFFIX = ".fix_expected.zig";
const FIX_STDOUT_OUTPUT_SUFFIX = ".fix_expected.stdout";

test "integration test rules" {
    const allocator = std.testing.allocator;

    var dir = try std.fs.cwd().openDir("./", .{});
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var tested_something = false;
    while (try walker.next()) |item| {
        if (!std.mem.endsWith(u8, item.path, INPUT_SUFFIX)) continue;

        // --------------------------------------------------------------------
        // Input and expected output files:
        // --------------------------------------------------------------------
        const name = item.basename[0..(item.basename.len - INPUT_SUFFIX.len)];
        const zig_input_file = try std.fmt.allocPrint(
            allocator,
            "./rules/{s}{s}",
            .{ name, INPUT_SUFFIX },
        );
        defer allocator.free(zig_input_file);

        const tmp_zig_input_file = try std.fmt.allocPrint(
            allocator,
            ".zig-cache/tmp/{s}{s}",
            .{ name, INPUT_SUFFIX },
        );
        defer allocator.free(tmp_zig_input_file);

        const lint_output_file = try std.fmt.allocPrint(
            allocator,
            "./rules/{s}{s}",
            .{ name, LINT_OUTPUT_SUFFIX },
        );
        defer allocator.free(lint_output_file);

        const fix_zig_output_file = try std.fmt.allocPrint(
            allocator,
            "./rules/{s}{s}",
            .{ name, FIX_ZIG_OUTPUT_SUFFIX },
        );
        defer allocator.free(fix_zig_output_file);

        const fix_stdout_output_file = try std.fmt.allocPrint(
            allocator,
            "./rules/{s}{s}",
            .{ name, FIX_STDOUT_OUTPUT_SUFFIX },
        );
        defer allocator.free(fix_stdout_output_file);

        // --------------------------------------------------------------------
        // Lint command "zig build lint -- <file>.zig"
        // --------------------------------------------------------------------
        {
            const lint_output = try runLintCommand(
                &.{
                    "zig",
                    "build",
                    "lint",
                    "--",
                    "--rule",
                    name,
                    zig_input_file,
                },
            );
            defer allocator.free(lint_output.stdout);
            defer allocator.free(lint_output.stderr);

            try std.testing.expectEqualStrings("", lint_output.stderr);
            try expectFileContentsEquals(
                dir,
                lint_output_file,
                lint_output.stdout,
            );
        }

        // --------------------------------------------------------------------
        // Fix command "zig build fix -- <file>.zig"
        // --------------------------------------------------------------------
        {
            try dir.copyFile(
                zig_input_file,
                dir,
                tmp_zig_input_file,
                .{},
            );

            const fix_output = try runLintCommand(
                &.{
                    "zig",
                    "build",
                    "lint",
                    "--",
                    "--fix",
                    tmp_zig_input_file,
                },
            );
            defer allocator.free(fix_output.stdout);
            defer allocator.free(fix_output.stderr);

            // Optional:
            if (dir.openFile(fix_zig_output_file, .{})) |_| {
                const actual = try dir.readFileAlloc(
                    std.testing.allocator,
                    tmp_zig_input_file,
                    MAX_FILE_SIZE_BYTES,
                );
                defer std.testing.allocator.free(actual);

                try expectFileContentsEquals(
                    dir,
                    fix_zig_output_file,
                    actual,
                );
            } else |_| {}

            if (dir.openFile(fix_stdout_output_file, .{})) |_| {
                try expectFileContentsEquals(
                    dir,
                    fix_stdout_output_file,
                    fix_output.stdout,
                );
            } else |_| {}
            try std.testing.expectEqualStrings("", fix_output.stderr);
        }

        tested_something = true;
    }
    try std.testing.expect(tested_something);
}

fn expectFileContentsEquals(dir: std.fs.Dir, file_path: []const u8, actual: []const u8) !void {
    const contents = dir.readFileAlloc(
        std.testing.allocator,
        file_path,
        MAX_FILE_SIZE_BYTES,
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try printWithHeader("Could not find file", file_path);
                return err;
            },
            else => return err,
        }
    };
    defer std.testing.allocator.free(contents);

    std.testing.expectEqualStrings(contents, actual) catch |err| {
        switch (err) {
            error.TestExpectedEqual => {
                try printWithHeader("Expected contents from", file_path);
                return err;
            },
        }
    };
}

fn printWithHeader(header: []const u8, content: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const top_bar = try std.fmt.bufPrint(
        &buffer,
        "======== {s} ========",
        .{header},
    );

    var bottom_bar = std.ArrayListUnmanaged(u8).empty;
    defer bottom_bar.deinit(std.testing.allocator);
    for (0..top_bar.len) |_| try bottom_bar.append(std.testing.allocator, '=');

    std.debug.print("{s}\n{s}\n{s}\n", .{ top_bar, content, bottom_bar.items });
}

fn runLintCommand(args: []const []const u8) !std.process.Child.RunResult {
    var map = try std.process.getEnvMap(std.testing.allocator);
    defer map.deinit();

    try map.put("NO_COLOR", "1");

    return try std.process.Child.run(.{
        .allocator = std.testing.allocator,
        .argv = args,
        .max_output_bytes = MAX_FILE_SIZE_BYTES,
        .env_map = &map,
    });
}
