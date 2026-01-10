const max_file_size_bytes = 10 * 1024 * 1024;
const input_zig_suffix = ".input.zig";
const input_zon_suffix = ".input.zon";
const lint_output_suffix = ".lint_expected.stdout";
const fix_zig_output_suffix = ".fix_expected.zig";
const fix_stdout_output_suffix = ".fix_expected.stdout";

pub fn runTest(
    io: std.Io,
    arena: std.mem.Allocator,
    args: []const [:0]const u8,
    environ_map: std.process.Environ.Map,
) !void {
    var input_zig_file: ?[:0]const u8 = null;
    var input_zon_file: ?[:0]const u8 = null;
    var lint_stdout_expected_file: ?[:0]const u8 = null;
    var fix_zig_expected_file: ?[:0]const u8 = null;
    var fix_stdout_expected_file: ?[:0]const u8 = null;

    // First arg is executable
    // Second arg is zig bin path
    // Third arg is rule name
    // Forth arg is test name
    const zig_bin = args[1]; // 1
    const rule_name = args[2]; // 2
    const test_name = args[3]; // 3
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

        try lint_args.appendSlice(arena, &.{
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
            try lint_args.appendSlice(arena, &.{
                "--rule-config",
                rule_name,
                file,
            });
        }

        const lint_output = try runLintCommand(
            lint_args.items,
            &environ_map,
            io,
            arena,
        );

        // TODO: Update to expect certain exit codes based on input
        // try std.testing.expect(lint_output.term.exited == 0);
        // try expectEqualStringsNormalized(arena, "", fix_output.stderr);

        expectFileContentsEquals(
            io,
            arena,
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
            arena,
            ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}.input.zig",
            .{rule_name},
        );

        try std.Io.Dir.cwd().copyFile(
            input_zig_file.?,
            std.Io.Dir.cwd(),
            temp_path,
            io,
            .{},
        );

        var lint_args = std.ArrayList([]const u8).empty;

        try lint_args.appendSlice(arena, &.{
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
            try lint_args.appendSlice(arena, &.{
                "--rule-config",
                rule_name,
                file,
            });
        }

        const fix_output = try runLintCommand(
            lint_args.items,
            &environ_map,
            io,
            arena,
        );

        // Expect all integration fix tests to be successful so exit 0 with
        // no stderr. Maybe one day we will add cases where it fails
        std.testing.expect(fix_output.term.exited == 0) catch |e| {
            std.log.err("stderr: {s}", .{fix_output.stderr});
            return e;
        };
        try expectEqualStringsNormalized(arena, "", fix_output.stderr);

        expectFileContentsEquals(
            io,
            arena,
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
            arena,
            .limited(max_file_size_bytes),
        );

        expectFileContentsEquals(
            io,
            arena,
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
    arena: std.mem.Allocator,
    dir: std.Io.Dir,
    file_path: []const u8,
    actual: []const u8,
) !void {
    const contents = dir.readFileAlloc(
        io,
        file_path,
        arena,
        .limited(max_file_size_bytes),
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try printWithHeader(arena, "Could not find file", file_path);
                return err;
            },
            else => return err,
        }
    };

    const normalized_expected = try normalizeNewLinesAlloc(contents, arena);
    const normalized_actual = try normalizeNewLinesAlloc(actual, arena);

    std.testing.expectEqualStrings(normalized_expected, normalized_actual) catch |err| {
        switch (err) {
            error.TestExpectedEqual => {
                try printWithHeader(arena, "Expected contents from", file_path);
                return err;
            },
        }
    };
}

fn expectEqualStringsNormalized(arena: std.mem.Allocator, expected: []const u8, actual: []const u8) !void {
    const normalized_expected = try normalizeNewLinesAlloc(expected, arena);
    const normalized_actual = try normalizeNewLinesAlloc(actual, arena);

    try std.testing.expectEqualStrings(normalized_expected, normalized_actual);
}

fn normalizeNewLinesAlloc(input: []const u8, arena: std.mem.Allocator) ![]const u8 {
    var result = std.ArrayList(u8).empty;

    // Removes "\r". e.g., "\r\n"
    for (input) |c| {
        switch (c) {
            '\r' => {}, // i.e., 0x0d
            // This assumes that '\' is never in output, which is currently true
            // If this ever changes we will need something more sophisticated
            // to identify strings that look like paths
            else => try result.append(arena, if (std.fs.path.isSep(c)) std.fs.path.sep_posix else c),
        }
    }

    return result.toOwnedSlice(arena);
}

fn printWithHeader(
    arena: std.mem.Allocator,
    header: []const u8,
    content: []const u8,
) !void {
    var buffer: [1024]u8 = undefined;
    const top_bar = try std.fmt.bufPrint(
        &buffer,
        "======== {s} ========",
        .{header},
    );

    const bottom_bar = try arena.alloc(u8, top_bar.len);
    @memset(bottom_bar, '=');

    std.debug.print("{s}\n{s}\n{s}\n", .{ top_bar, content, bottom_bar[0..] });
}

fn runLintCommand(
    args: []const []const u8,
    map: *const std.process.Environ.Map,
    io: std.Io,
    arena: std.mem.Allocator,
) !std.process.RunResult {
    return try std.process.run(
        arena,
        io,
        .{
            .argv = args,
            .max_output_bytes = max_file_size_bytes,
            .environ_map = map,
        },
    );
}

const std = @import("std");
