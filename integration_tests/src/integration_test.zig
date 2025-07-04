const max_file_size_bytes = 10 * 1024 * 1024;
const input_suffix = ".input.zig";
const lint_output_suffix = ".lint_expected.stdout";
const fix_zig_output_suffix = ".fix_expected.zig";
const fix_stdout_output_suffix = ".fix_expected.stdout";

test "integration test rules" {
    const allocator = std.testing.allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var input_zig_file: ?[:0]u8 = null;
    var lint_stdout_expected_file: ?[:0]u8 = null;
    var fix_zig_expected_file: ?[:0]u8 = null;
    var fix_stdout_expected_file: ?[:0]u8 = null;

    // First arg is executable
    // Second arg is rule name
    // Third arg is test name
    const rule_name = args[1];
    const test_name = args[2];
    _ = test_name;
    for (args[3..]) |arg| {
        if (std.mem.endsWith(u8, arg, input_suffix)) {
            input_zig_file = arg;
        } else if (std.mem.endsWith(u8, arg, lint_output_suffix)) {
            lint_stdout_expected_file = arg;
        } else if (std.mem.endsWith(u8, arg, fix_zig_output_suffix)) {
            fix_zig_expected_file = arg;
        } else if (std.mem.endsWith(u8, arg, fix_stdout_output_suffix)) {
            fix_stdout_expected_file = arg;
        } else {
            std.log.err("Unable to handle input file: {s}", .{arg});
            @panic("Failed");
        }
    }

    // TODO: Work out whats going wrong on windows
    if (std.mem.eql(u8, rule_name, "no_unused")) {
        switch (builtin.os.tag) {
            .windows, .uefi => return error.SkipZigTest,
            else => {},
        }
    }

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
                rule_name,
                "--include",
                input_zig_file.?,
            },
        );
        defer allocator.free(lint_output.stdout);
        defer allocator.free(lint_output.stderr);

        // TODO: Update to expect certain exit codes based on input
        // try std.testing.expect(lint_output.term.Exited == 0);
        // try std.testing.expectEqualStrings("", fix_output.stderr);

        switch (builtin.os.tag) {
            .windows, .uefi => {
                // Convert output into something that looks more like the posix
                // based expected output so that the tests can run on windows.
                var mutable = try allocator.dupe(u8, lint_output.stdout);
                defer allocator.free(mutable);

                // Replace "\" in file paths to "/"
                var offset: usize = 0;
                while (std.mem.indexOfPosLinear(u8, mutable, offset, "test_cases" ++ std.fs.path.sep_str)) |start| {
                    const end = std.mem.indexOfPosLinear(u8, mutable, start, ".zig").?;

                    for (start..end) |i| {
                        mutable[i] = if (std.fs.path.isSep(mutable[i])) std.fs.path.sep_posix else mutable[i];
                    }
                    offset = end;
                }

                try expectFileContentsEquals(
                    std.fs.cwd(),
                    lint_stdout_expected_file.?,
                    mutable,
                );
            },
            else => {
                try expectFileContentsEquals(
                    std.fs.cwd(),
                    lint_stdout_expected_file.?,
                    lint_output.stdout,
                );
            },
        }
    }

    // --------------------------------------------------------------------
    // Fix command "zig build fix -- <file>.zig"
    // --------------------------------------------------------------------
    if (fix_stdout_expected_file != null or fix_zig_expected_file != null) {
        const cwd = std.fs.cwd();
        var cache_dir = try cwd.makeOpenPath(".zig-cache", .{});
        defer cache_dir.close();

        var temp_dir = try cache_dir.makeOpenPath("tmp", .{});
        defer temp_dir.close();

        const temp_path = try std.fmt.allocPrint(
            std.testing.allocator,
            ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}.input.zig",
            .{rule_name},
        );
        defer allocator.free(temp_path);

        try std.fs.cwd().copyFile(
            input_zig_file.?,
            std.fs.cwd(),
            temp_path,
            .{},
        );

        const fix_output = try runLintCommand(
            &.{
                "zig",
                "build",
                "lint",
                "--",
                "--fix",
                "--include",
                temp_path,
            },
        );
        defer allocator.free(fix_output.stdout);
        defer allocator.free(fix_output.stderr);

        // Expect all integration fix tests to be successful so exit 0 with
        // no stderr. Maybe one day we will add cases where it fails
        try std.testing.expect(fix_output.term.Exited == 0);
        try std.testing.expectEqualStrings("", fix_output.stderr);

        try expectFileContentsEquals(
            std.fs.cwd(),
            fix_stdout_expected_file.?,
            fix_output.stdout,
        );

        const actual = try std.fs.cwd().readFileAlloc(
            allocator,
            temp_path,
            max_file_size_bytes,
        );

        defer allocator.free(actual);

        try expectFileContentsEquals(
            std.fs.cwd(),
            fix_zig_expected_file.?,
            actual,
        );

        try std.testing.expectEqualStrings("", fix_output.stderr);
    }
}

fn expectFileContentsEquals(dir: std.fs.Dir, file_path: []const u8, actual: []const u8) !void {
    const contents = dir.readFileAlloc(
        std.testing.allocator,
        file_path,
        max_file_size_bytes,
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

    const normalized_expected = try normalizeNewLinesAlloc(contents, std.testing.allocator);
    defer std.testing.allocator.free(normalized_expected);

    const normalized_actual = try normalizeNewLinesAlloc(actual, std.testing.allocator);
    defer std.testing.allocator.free(normalized_actual);

    std.testing.expectEqualStrings(normalized_expected, normalized_actual) catch |err| {
        switch (err) {
            error.TestExpectedEqual => {
                try printWithHeader("Expected contents from", file_path);
                return err;
            },
        }
    };
}

fn normalizeNewLinesAlloc(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    defer result.deinit();

    // Removes "\r". e.g., "\r\n"
    for (input) |c| {
        switch (c) {
            '\r' => {}, // i.e., 0x0d
            else => try result.append(c),
        }
    }

    return result.toOwnedSlice();
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
        .max_output_bytes = max_file_size_bytes,
        .env_map = &map,
    });
}

const std = @import("std");
const builtin = @import("builtin");
