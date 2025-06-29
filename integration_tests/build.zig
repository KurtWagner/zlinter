const input_suffix = ".input.zig";

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run tests");

    const data_path = b.path("rules/").getPath3(b, null).sub_path;
    var dir = try std.fs.cwd().openDir(data_path, .{});
    defer dir.close();

    var walker = try dir.walk(b.allocator);
    defer walker.deinit();

    while (try walker.next()) |item| {
        if (!std.mem.endsWith(u8, item.path, input_suffix)) continue;

        const run_integration_test = b.addRunArtifact(b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/integration_test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .test_runner = .{
                .path = b.path("src/test_runner.zig"),
                .mode = .simple,
            },
        }));

        var buffer: [2048]u8 = undefined;
        const name = item.basename[0..(item.basename.len - input_suffix.len)];
        run_integration_test.addArg(name);
        inline for (&.{
            ".input.zig",
            ".lint_expected.stdout",
            ".fix_expected.stdout",
            ".fix_expected.zig",
        }) |suffix| {
            addFileArgIfExists(
                b,
                run_integration_test,
                std.fmt.bufPrint(&buffer, "{s}/{s}{s}", .{ data_path, name, suffix }) catch unreachable,
            );
        }
        test_step.dependOn(&run_integration_test.step);
    }

    // zig build lint -
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{ .target = target, .optimize = optimize });
        try builder.addRule(.{ .builtin = .no_unused }, .{});
        try builder.addRule(.{ .builtin = .no_undefined }, .{});
        try builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        try builder.addRule(.{ .builtin = .field_naming }, .{});
        try builder.addRule(.{ .builtin = .declaration_naming }, .{});
        try builder.addRule(.{ .builtin = .function_naming }, .{
            .function_that_returns_type = .{
                .severity = .warning,
                .style = .title_case,
            },
        });
        try builder.addRule(.{ .builtin = .file_naming }, .{});
        try builder.addRule(.{ .builtin = .no_deprecation }, .{});
        try builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        try builder.addRule(.{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, .{
            .message = "I'm allergic to cats",
        });
        break :step try builder.build();
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
