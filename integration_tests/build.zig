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
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_panic }, .{});
        builder.addRule(.{ .builtin = .no_undefined }, .{});
        builder.addRule(.{ .builtin = .require_doc_comment }, .{});
        builder.addRule(.{ .builtin = .max_positional_args }, .{});
        builder.addRule(.{ .builtin = .no_literal_args }, .{
            .detect_string_literal = .@"error",
            .detect_char_literal = .@"error",
            .exclude_fn_names = &.{ "excludeFnName", "print" },
        });
        builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        builder.addRule(.{ .builtin = .field_naming }, .{});
        builder.addRule(.{ .builtin = .declaration_naming }, .{});
        builder.addRule(.{ .builtin = .function_naming }, .{
            .function_that_returns_type = .{
                .severity = .warning,
                .style = .title_case,
            },
        });
        builder.addRule(.{ .builtin = .file_naming }, .{});
        builder.addRule(.{ .builtin = .no_deprecated }, .{});
        builder.addRule(.{ .builtin = .no_inferred_error_unions }, .{});
        builder.addRule(.{ .builtin = .no_hidden_allocations }, .{});
        builder.addRule(.{ .builtin = .no_swallow_error }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addRule(.{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, .{
            .message = "I'm allergic to cats",
        });
        break :step builder.build();
    });
}

fn addFileArgIfExists(b: *std.Build, step: *std.Build.Step.Run, raw_path: []const u8) void {
    var path = b.path(raw_path);
    const relative_path = path.getPath3(b, &step.step).sub_path;
    const exists = if (std.fs.cwd().access(relative_path, .{})) true else |e| e != error.FileNotFound;
    if (exists) {
        step.addFileArg(path);
    }
}

const zlinter = @import("zlinter");
const std = @import("std");
