const input_suffix = ".input.zig";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const io = b.graph.io;

    const test_focus_on_rule = b.option([]const u8, "test_focus_on_rule", "Only run tests for this rule");
    const test_step = b.step("test", "Run tests");

    const test_cases_path = "test_cases/";
    var test_cases_dir = try std.Io.Dir.cwd().openDir(io, test_cases_path, .{ .iterate = true });
    defer test_cases_dir.close(io);

    var walker = try test_cases_dir.walk(b.allocator);
    defer walker.deinit();

    const test_runner_module = b.createModule(.{
        .root_source_file = b.path("src/test_runner.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_runner_exe = b.addExecutable(.{
        .name = "integration_tests",
        .root_module = test_runner_module,
    });

    var run_integration_test_steps: std.ArrayList(*std.Build.Step) = .empty;
    defer run_integration_test_steps.deinit(b.allocator);

    while (try walker.next(io)) |item| {
        if (item.kind != .file) continue;
        if (!std.mem.endsWith(u8, item.path, input_suffix)) continue;

        // Format: <rule_name>/<test_name>.input.zig
        const rule_name = item.path[0 .. std.mem.indexOfScalar(u8, item.path, std.fs.path.sep) orelse {
            std.log.err("Test case file skipped as its invalid: {s}", .{item.path});
            continue;
        }];
        if (test_focus_on_rule) |r| {
            if (!std.mem.eql(u8, rule_name, r)) {
                std.log.warn("Skipping {s}", .{rule_name});
                continue;
            }
        }

        const test_name = item.basename[0..(item.basename.len - input_suffix.len)];

        const run_integration_test = b.addRunArtifact(test_runner_exe);
        run_integration_test.addArg(b.graph.zig_exe);
        run_integration_test.addArg(rule_name);
        run_integration_test.addArg(test_name);

        var buffer: [2048]u8 = undefined;
        inline for (&.{
            ".input.zig",
            ".lint_expected.stdout",
            ".fix_expected.stdout",
            ".fix_expected.zig",
            ".input.zon",
        }) |suffix| {
            addFileArgIfExists(
                b,
                run_integration_test,
                std.fmt.bufPrint(&buffer, "{s}/{s}/{s}{s}", .{ test_cases_path, rule_name, test_name, suffix }) catch unreachable,
            );
        }
        try run_integration_test_steps.append(b.allocator, &run_integration_test.step);
    }

    for (run_integration_test_steps.items) |run_integration_test_step| {
        test_step.dependOn(run_integration_test_step);
    }

    // zig build lint -
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{ .target = target });
        inline for (@typeInfo(zlinter.BuiltinLintRule).@"enum".field_values) |field_value| {
            builder.addRule(.{ .builtin = @enumFromInt(field_value) }, .{});
        }
        builder.addRule(.{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, .{});
        break :step builder.build();
    });
}

fn addFileArgIfExists(b: *std.Build, step: *std.Build.Step.Run, raw_path: []const u8) void {
    const path = b.path(raw_path);
    const exists = if (std.Io.Dir.cwd().access(b.graph.io, raw_path, .{})) true else |e| e != error.FileNotFound;
    if (exists) {
        step.addFileArg(path);
    }
}

const std = @import("std");
const zlinter = @import("zlinter");
