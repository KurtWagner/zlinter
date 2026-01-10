const max_file_size_bytes = 10 * 1024 * 1024;
const input_zig_suffix = ".input.zig";
const input_zon_suffix = ".input.zon";
const lint_output_suffix = ".lint_expected.stdout";
const fix_zig_output_suffix = ".fix_expected.zig";
const fix_stdout_output_suffix = ".fix_expected.stdout";

test "integration test rules" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    var args: std.process.Args = undefined;
    var args_it = try std.process.Args.iterateAllocator(args, allocator);
    defer args_it.deinit();
    args_it.skip();

    defer std.process.argsFree(allocator, args);

    var input_zig_file: ?[:0]u8 = null;
    var input_zon_file: ?[:0]u8 = null;
    var lint_stdout_expected_file: ?[:0]u8 = null;
    var fix_zig_expected_file: ?[:0]u8 = null;
    var fix_stdout_expected_file: ?[:0]u8 = null;

    // First arg is executable
    // Second arg is zig bin path
    // Third arg is rule name
    // Forth arg is test name
    const zig_bin = args_it.next();
    const rule_name = args_it.next();
    const test_name = args_it.next();
    _ = test_name;
    for (args[4..]) |arg| {
        if (std.mem.endsWith(u8, arg, input_zig_suffix)) {
            input_zig_file = arg;
        } else if (std.mem.endsWith(u8, arg, lint_output_suffix)) {
            lint_stdout_expected_file = arg;
        } else if (std.mem.endsWith(u8, arg, fix_zig_output_suffix)) {
            fix_zig_expected_file = arg;
        } else if (std.mem.endsWith(u8, arg, fix_stdout_output_suffix)) {
            fix_stdout_expected_file = arg;
        } else if (std.mem.endsWith(u8, arg, input_zon_suffix)) {
            input_zon_file = arg;
        } else {
            std.log.err("Unable to handle input file: {s}", .{arg});
            @panic("Failed");
        }
    }

    // --------------------------------------------------------------------
    // Lint command "zig build lint -- <file>.zig"
    // --------------------------------------------------------------------
    {
        var lint_args = std.ArrayList([]const u8).empty;
        defer lint_args.deinit(std.testing.allocator);

        try lint_args.appendSlice(std.testing.allocator, &.{
            zig_bin,
            "build",
            "lint",
            "--",
            "--rule",
            rule_name,
            "--include",
            input_zig_file.?,
        });
        if (input_zon_file) |file| {
            try lint_args.appendSlice(std.testing.allocator, &.{
                "--rule-config",
                rule_name,
                file,
            });
        }

        const lint_output = try runLintCommand(lint_args.items);
        defer allocator.free(lint_output.stdout);
        defer allocator.free(lint_output.stderr);

        // TODO: Update to expect certain exit codes based on input
        // try std.testing.expect(lint_output.term.Exited == 0);
        // try expectEqualStringsNormalized("", fix_output.stderr);

        expectFileContentsEquals(
            io,
            allocator,
            std.Io.Dir.cwd(),
            lint_stdout_expected_file.?,
            lint_output.stdout,
        ) catch |e| {
            std.log.err("stderr: {s}", .{lint_output.stderr});
            return e;
        };
    }

    // --------------------------------------------------------------------
    // Fix command "zig build fix -- <file>.zig"
    // --------------------------------------------------------------------
    if (fix_stdout_expected_file != null or fix_zig_expected_file != null) {
        const cwd = std.Io.Dir.cwd();
        var cache_dir = try cwd.createDirPathOpen(io, ".zig-cache", .{});
        defer cache_dir.close(io);

        var temp_dir = try cache_dir.createDirPathOpen(io, "tmp", .{});
        defer temp_dir.close(io);

        const temp_path = try std.fmt.allocPrint(
            std.testing.allocator,
            ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}.input.zig",
            .{rule_name},
        );
        defer allocator.free(temp_path);

        try std.Io.Dir.cwd().copyFile(
            input_zig_file.?,
            std.Io.Dir.cwd(),
            temp_path,
            io,
            .{},
        );

        var lint_args = std.ArrayList([]const u8).empty;
        defer lint_args.deinit(std.testing.allocator);

        try lint_args.appendSlice(std.testing.allocator, &.{
            zig_bin,
            "build",
            "lint",
            "--",
            "--rule",
            rule_name,
            "--fix",
            "--include",
            temp_path,
        });
        if (input_zon_file) |file| {
            try lint_args.appendSlice(std.testing.allocator, &.{
                "--rule-config",
                rule_name,
                file,
            });
        }

        const fix_output = try runLintCommand(lint_args.items);
        defer allocator.free(fix_output.stdout);
        defer allocator.free(fix_output.stderr);

        // Expect all integration fix tests to be successful so exit 0 with
        // no stderr. Maybe one day we will add cases where it fails
        std.testing.expect(fix_output.term.Exited == 0) catch |e| {
            std.log.err("stderr: {s}", .{fix_output.stderr});
            return e;
        };
        try expectEqualStringsNormalized("", fix_output.stderr);

        expectFileContentsEquals(
            io,
            allocator,
            std.Io.Dir.cwd(),
            fix_stdout_expected_file.?,
            fix_output.stdout,
        ) catch |e| {
            std.log.err("stderr: {s}", .{fix_output.stderr});
            return e;
        };

        const actual = try std.Io.Dir.cwd().readFileAlloc(
            io,
            temp_path,
            allocator,
            .limited(max_file_size_bytes),
        );
        defer allocator.free(actual);

        expectFileContentsEquals(
            io,
            allocator,
            std.Io.Dir.cwd(),
            fix_zig_expected_file.?,
            actual,
        ) catch |e| {
            std.log.err("stderr: {s}", .{fix_output.stderr});
            return e;
        };
    }
}

fn expectFileContentsEquals(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    file_path: []const u8,
    actual: []const u8,
) !void {
    const contents = dir.readFileAlloc(
        io,
        file_path,
        allocator,
        .limited(max_file_size_bytes),
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try printWithHeader("Could not find file", file_path);
                return err;
            },
            else => return err,
        }
    };
    defer allocator.free(contents);

    const normalized_expected = try normalizeNewLinesAlloc(contents, allocator);
    defer allocator.free(normalized_expected);

    const normalized_actual = try normalizeNewLinesAlloc(actual, allocator);
    defer allocator.free(normalized_actual);

    std.testing.expectEqualStrings(normalized_expected, normalized_actual) catch |err| {
        switch (err) {
            error.TestExpectedEqual => {
                try printWithHeader("Expected contents from", file_path);
                return err;
            },
        }
    };
}

fn expectEqualStringsNormalized(expected: []const u8, actual: []const u8) !void {
    const normalized_expected = try normalizeNewLinesAlloc(expected, std.testing.allocator);
    defer std.testing.allocator.free(normalized_expected);

    const normalized_actual = try normalizeNewLinesAlloc(actual, std.testing.allocator);
    defer std.testing.allocator.free(normalized_actual);

    try std.testing.expectEqualStrings(normalized_expected, normalized_actual);
}

fn normalizeNewLinesAlloc(input: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    defer result.deinit(allocator);

    // Removes "\r". e.g., "\r\n"
    for (input) |c| {
        switch (c) {
            '\r' => {}, // i.e., 0x0d
            // This assumes that '\' is never in output, which is currently true
            // If this ever changes we will need something more sophisticated
            // to identify strings that look like paths
            else => try result.append(allocator, if (std.fs.path.isSep(c)) std.fs.path.sep_posix else c),
        }
    }

    return result.toOwnedSlice(allocator);
}

fn printWithHeader(header: []const u8, content: []const u8) !void {
    var buffer: [1024]u8 = undefined;
    const top_bar = try std.fmt.bufPrint(
        &buffer,
        "======== {s} ========",
        .{header},
    );

    const bottom_bar = try std.testing.allocator.alloc(u8, top_bar.len);
    defer std.testing.allocator.free(bottom_bar);
    @memset(bottom_bar, '=');

    std.debug.print("{s}\n{s}\n{s}\n", .{ top_bar, content, bottom_bar[0..] });
}

fn runLintCommand(args: []const []const u8) !std.process.Child.RunResult {
    var map = try std.process.getEnvMap(std.testing.allocator);
    defer map.deinit();

    try map.put("NO_COLOR", "1");

    return try std.process.Child.run(std.testing.allocator, std.testing.io, .{
        .argv = args,
        .max_output_bytes = max_file_size_bytes,
        .env_map = &map,
    });
}

const std = @import("std");
