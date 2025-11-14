const input_suffix = ".input.zig";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run tests");

    const test_cases_path = b.path("test_cases/").getPath3(b, null).sub_path;
    var test_cases_dir = try std.fs.cwd().openDir(test_cases_path, .{ .iterate = true });
    defer test_cases_dir.close();

    var walker = try test_cases_dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |item| {
        if (item.kind != .file) continue;
        if (!std.mem.endsWith(u8, item.path, input_suffix)) continue;

        const integration_test_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test.zig"),
            .target = target,
            .optimize = optimize,
        });
        if (zlinter.version.zig == .@"0.15" and target.result.os.tag == .windows) {
            integration_test_module.linkSystemLibrary("advapi32", .{});
        }
        const run_integration_test = b.addRunArtifact(b.addTest(.{
            .root_module = integration_test_module,
            .test_runner = .{
                .path = b.path("src/test_runner.zig"),
                .mode = .simple,
            },
        }));
        run_integration_test.addArg(b.graph.zig_exe);

        // Format: <rule_name>/<test_name>.input.zig
        const rule_name = item.path[0 .. std.mem.indexOfScalar(u8, item.path, std.fs.path.sep) orelse {
            std.log.err("Test case file skipped as its invalid: {s}", .{item.path});
            continue;
        }];
        run_integration_test.addArg(rule_name);

        const test_name = item.basename[0..(item.basename.len - input_suffix.len)];
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
        test_step.dependOn(&run_integration_test.step);
    }

    // zig build lint -
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{ .target = target, .optimize = optimize });
        inline for (@typeInfo(zlinter.BuiltinLintRule).@"enum".fields) |field| {
            builder.addRule(.{ .builtin = @enumFromInt(field.value) }, .{});
        }
        builder.addRule(.{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, .{});
        break :step builder.build();
    });

    // See: src/check_compiled_source/README.md
    {
        const lint_integration_cmd = b.step("check-compiled-source", "");
        lint_integration_cmd.dependOn(step: {
            var builder = zlinter.builder(b, .{ .target = target, .optimize = optimize });
            builder.addRule(
                .{ .custom = .{
                    .name = "no_cats",
                    .path = "src/no_cats.zig",
                } },
                .{
                    .severity = .@"error",
                },
            );
            builder.addRule(
                .{ .builtin = .no_panic },
                .{ .severity = .warning },
            );
            builder.addSource(.compiled(b.addLibrary(.{
                .name = "main",
                .root_module = b.addModule("main", .{
                    .root_source_file = b.path("src/check_compiled_source/main.zig"),
                    .target = target,
                    .optimize = optimize,
                }),
            })));
            builder.addPaths(.{ .exclude = &.{b.path("src/check_compiled_source/excluded.zig")} });
            break :step builder.build();
        });
    }
}

fn addFileArgIfExists(b: *std.Build, step: *std.Build.Step.Run, raw_path: []const u8) void {
    var path = b.path(raw_path);
    const relative_path = path.getPath3(b, &step.step).sub_path;
    const exists = if (std.fs.cwd().access(relative_path, .{})) true else |e| e != error.FileNotFound;
    if (exists) {
        step.addFileArg(path);
    }
}

const std = @import("std");
const zlinter = @import("zlinter");
