const input_suffix = ".input.zig";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const io = b.graph.io;

    const test_focus_on_rule = b.option([]const u8, "test_focus_on_rule", "Only run tests for this rule");
    const test_step = b.step("test", "Run tests");

    const test_cases_path = "test_cases/";
    var test_cases_dir = try std.Io.Dir.cwd().openDir(
        io,
        test_cases_path,
        .{ .iterate = true },
    );
    defer test_cases_dir.close(io);

    var walker = try test_cases_dir.walk(b.allocator);
    defer walker.deinit();

    createCompiledUnits(b, target, optimize);

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

        const parent_dir = std.Io.Dir.path.dirname(item.path).?;

        // Format: <rule_name>/<test_name>/<test_name>.input.zig
        const rule_name = item.path[0 .. std.mem.findScalar(u8, item.path, std.Io.Dir.path.sep) orelse {
            std.log.err("Test case file skipped as its invalid: {s}", .{item.path});
            continue;
        }];
        if (test_focus_on_rule) |r|
            if (!std.mem.eql(u8, rule_name, r)) {
                std.log.warn("Skipping {s}", .{rule_name});
                continue;
            };

        const test_name = item.basename[0..(item.basename.len - input_suffix.len)];

        const run_integration_test = b.addRunArtifact(test_runner_exe);
        run_integration_test.addArg(b.graph.zig_exe);
        run_integration_test.addArg(rule_name);
        run_integration_test.addArg(test_name);

        var filename_buffer: [std.Io.Dir.max_name_bytes]u8 = undefined;
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var path_fba: std.heap.FixedBufferAllocator = .init(&path_buffer);
        inline for (&.{
            ".input.zig",
            ".lint_expected.stdout",
            ".fix_expected.stdout",
            ".fix_expected.zig",
        }) |suffix| {
            const filename = std.mem.print(
                &filename_buffer,
                "{s}{s}",
                .{ test_name, suffix },
            ) catch unreachable;

            const input_path = std.Io.Dir.path.resolve(
                path_fba.allocator(),
                &.{ test_cases_path, parent_dir, filename },
            ) catch unreachable;

            addFileArgIfExists(
                b,
                run_integration_test,
                input_path,
            );
        }
        try run_integration_test_steps.append(b.allocator, &run_integration_test.step);
    }

    for (run_integration_test_steps.items) |run_integration_test_step|
        test_step.dependOn(run_integration_test_step);

    // zig build lint -
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{ .target = target });
        inline for (@typeInfo(zlinter.BuiltinLintRule).@"enum".field_values) |field_value|
            builder.addRule(.{ .builtin = @enumFromInt(field_value) }, .{});
        builder.setCompileUnits(&.{.all});
        builder.addRule(.{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, .{});
        break :step builder.build();
    });
}

fn addFileArgIfExists(b: *std.Build, step: *std.Build.Step.Run, raw_path: []const u8) void {
    const path = b.path(raw_path);
    const exists = if (std.Io.Dir.cwd().access(b.graph.io, raw_path, .{})) true else |e| e != error.FileNotFound;
    if (exists)
        step.addFileArg(path);
}

/// Creates compiled units that the linter should be capable of discovering
/// and walking for tests that care about the cross module coverage.
fn createCompiledUnits(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.OptimizeMode,
) void {
    const sub_module_a = b.createModule(.{
        .root_source_file = b.path("sub_module_a_src/root.zig"),
    });

    const sub_module_b = b.createModule(.{
        .root_source_file = b.path("sub_module_b_src/root.zig"),
    });

    const fake_install_cmd = b.step(
        "install-tests-with-sub-modules",
        "Fake step to install tests that depend on fake modules.",
    );

    // Any test that wants to import "sub_module" should add itself here. It'll
    // create two compiled units that use sub module a and sub module b as imports
    // for "sub_module", allowing tests to cover multiple implementations and
    // dependency graphs of compiled units.
    for ([_][]const u8{
        "test_cases/declaration_naming/sub_module_resolution/sub_module_resolution.input.zig",
        "test_cases/field_naming/sub_module_resolution/sub_module_resolution.input.zig",
        "test_cases/function_naming/sub_module_resolution/sub_module_resolution.input.zig",
        "test_cases/no_deprecated/sub_module_resolution/sub_module_resolution.input.zig",
        "test_cases/require_exhaustive_enum_switch/ambiguous_enum_candidates/ambiguous_enum_candidates.input.zig",
    }) |rel_path| {
        const path = b.path(rel_path);

        const name: []u8 = b.allocator.dupe(u8, rel_path) catch unreachable;
        std.mem.replaceScalar(u8, name, '/', '-');

        const step_a =
            b.addInstallArtifact(
                b.addLibrary(.{
                    .name = name,
                    .root_module = b.createModule(.{
                        .root_source_file = path,
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{
                                .name = "sub_module",
                                .module = sub_module_a,
                            },
                        },
                    }),
                }),
                .{},
            );

        fake_install_cmd.dependOn(&step_a.step);

        const step_b =
            b.addInstallArtifact(
                b.addLibrary(.{
                    .name = "fake_library_b",
                    .root_module = b.createModule(.{
                        .root_source_file = path,
                        .target = target,
                        .optimize = optimize,
                        .imports = &.{
                            .{
                                .name = "sub_module",
                                .module = sub_module_b,
                            },
                        },
                    }),
                }),
                .{},
            );
        fake_install_cmd.dependOn(&step_b.step);
    }
}

const std = @import("std");
const zlinter = @import("zlinter");
