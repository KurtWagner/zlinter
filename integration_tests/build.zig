pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zig build test -
    const run_integration_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    }));
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_integration_tests.step);

    // zig build lint -
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{ .target = target, .optimize = optimize });
        try builder.addRule(.{ .builtin = .no_unused }, .{});
        try builder.addRule(.{ .builtin = .field_naming }, .{});
        try builder.addRule(.{ .builtin = .declaration_naming }, .{});
        try builder.addRule(.{ .builtin = .function_naming }, .{});
        try builder.addRule(.{ .builtin = .file_naming }, .{});
        try builder.addRule(.{ .builtin = .no_deprecation }, .{});
        try builder.addRule(.{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, .{});
        break :step try builder.build();
    });
}

const zlinter = @import("zlinter");
const std = @import("std");
