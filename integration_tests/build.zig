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
    const options = zlinter.BuildRuleOptions{ .target = target, .optimize = optimize };
    lint_cmd.dependOn(try zlinter.buildStep(b, .{
        .target = target,
        .optimize = optimize,
        .rules = &.{
            zlinter.buildRule(b, .{ .builtin = .no_unused_container_declarations }, options),
            zlinter.buildRule(b, .{ .builtin = .field_naming }, options),
            zlinter.buildRule(b, .{ .builtin = .declaration_naming }, options),
            zlinter.buildRule(b, .{ .builtin = .function_naming }, options),
            zlinter.buildRule(b, .{ .builtin = .file_naming }, options),
            zlinter.buildRule(b, .{ .builtin = .no_deprecation }, options),
            zlinter.buildRule(b, .{ .custom = .{ .name = "no_cats", .path = "src/no_cats.zig" } }, options),
        },
    }));
}

const zlinter = @import("zlinter");
const std = @import("std");
