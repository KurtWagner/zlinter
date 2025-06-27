const std = @import("std");

pub const BuildStepOptions = struct {
    /// List of rules created with `buildRule`
    rules: []const std.Build.Module.Import,

    /// You should never need to set this. Defaults to native host.
    target: ?std.Build.ResolvedTarget = null,

    /// You should never need to set this. Leave it to be managed by zlinter
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub const BuiltinLintRule = enum {
    no_unused_container_declarations,
    field_naming,
    declaration_naming,
    function_naming,
    file_naming,
    no_deprecation,
};

pub const BuildRuleOptions = struct {
    /// You should never need to set this. Defaults to native host.
    target: ?std.Build.ResolvedTarget = null,

    /// You should never need to set this. Leave it to be managed by zlinter
    optimize: std.builtin.OptimizeMode = .Debug,
};

pub const BuildRuleSource = union(enum) {
    builtin: BuiltinLintRule,
    custom: struct {
        name: []const u8,
        path: []const u8,
    },
};

pub const BuildStepError = error{
    OutOfMemory,
    InvalidConfig,
};

/// Used to integrate the linter into other packages build.zig.
pub fn buildStep(
    b: *std.Build,
    options: BuildStepOptions,
) BuildStepError!*std.Build.Step {
    return try buildStepWithDependency(
        b,
        options.rules,
        .{
            .target = options.target,
            .optimize = options.optimize,
            .zlinter = .{ .dependency = b.dependencyFromBuildZig(@This(), .{}) },
        },
    );
}

/// Used in conjunction with `buildStep` to add rules to other packages build.zig
pub fn buildRule(
    b: *std.Build,
    comptime source: BuildRuleSource,
    options: BuildRuleOptions,
) std.Build.Module.Import {
    const zlinter_import = std.Build.Module.Import{
        .name = "zlinter",
        .module = b.dependencyFromBuildZig(@This(), .{}).module("zlinter"),
    };
    return switch (source) {
        .builtin => |builtin| buildRuleWithDependency(
            b,
            builtin,
            .{
                .target = options.target,
                .optimize = options.optimize,
                .zlinter_dependency = b.dependencyFromBuildZig(@This(), .{}),
                .zlinter_import = zlinter_import,
            },
        ),
        .custom => |custom| .{
            .name = checkNoNameCollision(custom.name),
            .module = b.createModule(.{
                .root_source_file = b.path(custom.path),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{zlinter_import},
            }),
        },
    };
}

// const zlinter_json_config_file_name = ".zlinter.json";
const zlinter_zon_config_file_name = "zlinter.zon";

/// zlinters own build file for running its tests and itself on itself
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlinter_lib_module = b.addModule("zlinter", .{
        .root_source_file = b.path("src/lib/zlinter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{
            .name = "zls",
            .module = b.dependency("zls", .{
                .target = target,
                .optimize = optimize,
            }).module("zls"),
        }},
    });

    const zlinter_import = std.Build.Module.Import{
        .name = "zlinter",
        .module = zlinter_lib_module,
    };

    const run_unit_tests = b.addRunArtifact(b.addTest(
        .{ .root_module = zlinter_lib_module },
    ));

    // --------------------------------------------------------------------
    // Generate dynamic rules list and configs
    // --------------------------------------------------------------------
    var rule_imports: [@typeInfo(BuiltinLintRule).@"enum".fields.len]std.Build.Module.Import = undefined;
    inline for (std.meta.fields(BuiltinLintRule), 0..) |enum_type, i| {
        const rule_module = b.createModule(.{
            .root_source_file = b.path("src/rules/" ++ enum_type.name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{zlinter_import},
        });

        // Rule unit tests:
        const run_rule_unit_tests = b.addRunArtifact(b.addTest(.{
            .root_module = rule_module,
        }));
        run_unit_tests.step.dependOn(&run_rule_unit_tests.step);

        // Rule as import:
        rule_imports[i] = .{
            .name = enum_type.name,
            .module = rule_module,
        };
    }

    const build_rules_step, const build_rules_output = addBuildRulesStep(
        b,
        b.path("build_rules.zig"),
        &rule_imports,
    );
    const rules_module = try createRulesModule(
        b,
        zlinter_import,
        &rule_imports,
        build_rules_output,
    );

    const build_rules_config_step = addBuildRulesConfigStep(
        b,
        b.path("build_rules_config.zig"),
        rules_module,
        zlinter_lib_module,
    );
    build_rules_config_step.step.dependOn(&build_rules_step.step);
    addOptionalFileArg(b, build_rules_config_step, zlinter_zon_config_file_name);
    // addOptionalFileArg(b, build_rules_config_step, zlinter_json_config_file_name);

    // ------------------------------------------------------------------------
    // zig build test
    // ------------------------------------------------------------------------
    const run_integration_tests = b.addRunArtifact(b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/exe/run_integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{zlinter_import},
        }),
    }));

    const unit_test_step = b.step("unit-test", "Run unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);

    // ------------------------------------------------------------------------
    // zig build lint
    // ------------------------------------------------------------------------
    const lint_cmd = b.step("lint", "Lint the linters own source code.");
    lint_cmd.dependOn(try buildStepWithDependency(
        b,
        &.{
            buildRuleWithDependency(b, .no_unused_container_declarations, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }),
            buildRuleWithDependency(b, .field_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }),
            buildRuleWithDependency(b, .declaration_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }),
            buildRuleWithDependency(b, .function_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }),
            buildRuleWithDependency(b, .file_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }),
            buildRuleWithDependency(b, .no_deprecation, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }),
        },
        .{
            .target = target,
            .optimize = optimize,
            .zlinter = .{ .module = zlinter_lib_module },
        },
    ));
}

fn buildStepWithDependency(
    b: *std.Build,
    rule_imports: []const std.Build.Module.Import,
    options: struct {
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,

        zlinter: union(enum) {
            dependency: *std.Build.Dependency,
            module: *std.Build.Module,
        },
    },
) BuildStepError!*std.Build.Step {
    const zlinter_lib_module: *std.Build.Module, const exe_file: std.Build.LazyPath, const build_rules_exe_file: std.Build.LazyPath, const build_rules_config_exe_file: std.Build.LazyPath = switch (options.zlinter) {
        .dependency => |d| .{ d.module("zlinter"), d.path("src/exe/run_linter.zig"), d.path("build_rules.zig"), d.path("build_rules_config.zig") },
        .module => |m| .{ m, b.path("src/exe/run_linter.zig"), b.path("build_rules.zig"), b.path("build_rules_config.zig") },
    };

    const zlinter_import = std.Build.Module.Import{ .name = "zlinter", .module = zlinter_lib_module };

    // --------------------------------------------------------------------
    // Generate linter exe
    // --------------------------------------------------------------------

    const exe_module = b.createModule(.{
        .root_source_file = exe_file,
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{zlinter_import},
    });

    // --------------------------------------------------------------------
    // Generate dynamic rules and rules config
    // --------------------------------------------------------------------

    const build_rules_step, const build_rules_output = addBuildRulesStep(b, build_rules_exe_file, rule_imports);
    const rules_module = try createRulesModule(
        b,
        zlinter_import,
        rule_imports,
        build_rules_output,
    );
    exe_module.addImport("rules", rules_module);

    const build_rules_config_step = addBuildRulesConfigStep(
        b,
        build_rules_config_exe_file,
        rules_module,
        zlinter_lib_module,
    );
    build_rules_config_step.step.dependOn(&build_rules_step.step);

    exe_module.addImport("rules_config", b.createModule(.{
        .root_source_file = build_rules_config_step.addOutputFileArg("rules_config.zon"),
        .imports = &.{},
    }));
    addOptionalFileArg(b, build_rules_config_step, zlinter_zon_config_file_name);
    // addOptionalFileArg(b, build_rules_config_step, zlinter_json_config_file_name);

    // --------------------------------------------------------------------
    // Generate linter exe
    // --------------------------------------------------------------------

    const exe = b.addExecutable(.{
        .name = "zlinter",
        .root_module = exe_module,
    });

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    run_cmd.addArgs(&.{ "--zig_exe", b.graph.zig_exe });
    if (b.graph.global_cache_root.path) |p|
        run_cmd.addArgs(&.{ "--global_cache_root", p });

    if (b.graph.zig_lib_directory.path) |p|
        run_cmd.addArgs(&.{ "--zig_lib_directory", p });

    return &run_cmd.step;
}

fn checkNoNameCollision(comptime name: []const u8) []const u8 {
    comptime {
        for (std.meta.fieldNames(BuiltinLintRule)) |core_name| {
            if (std.ascii.eqlIgnoreCase(core_name, name)) {
                @compileError(name ++ " collides with a core rule. Consider prefixing your rule with a namespace. e.g., yourname.some_rule");
            }
        }
    }
    return name;
}

fn buildRuleWithDependency(
    b: *std.Build,
    rule: BuiltinLintRule,
    options: struct {
        target: ?std.Build.ResolvedTarget = null,
        optimize: ?std.builtin.OptimizeMode = null,
        zlinter_dependency: ?*std.Build.Dependency = null,
        zlinter_import: std.Build.Module.Import,
    },
) std.Build.Module.Import {
    return switch (rule) {
        inline else => |inline_rule| .{
            .name = @tagName(inline_rule),
            .module = b.createModule(.{
                .root_source_file = if (options.zlinter_dependency) |d| d.path("src/rules/" ++ @tagName(inline_rule) ++ ".zig") else b.path("src/rules/" ++ @tagName(inline_rule) ++ ".zig"),
                .target = options.target,
                .optimize = options.optimize,
                .imports = &.{options.zlinter_import},
            }),
        },
    };
}

fn addBuildRulesConfigStep(
    b: *std.Build,
    root_source_file: std.Build.LazyPath,
    rules_module: *std.Build.Module,
    zlinter_lib_module: *std.Build.Module,
) *std.Build.Step.Run {
    return b.addRunArtifact(b.addExecutable(.{
        .name = "build_rules_config",
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{
                    .name = "rules",
                    .module = rules_module,
                },
                .{
                    .name = "zlinter",
                    .module = zlinter_lib_module,
                },
            },
        }),
    }));
}

fn addBuildRulesStep(
    b: *std.Build,
    root_source_path: std.Build.LazyPath,
    rule_imports: []const std.Build.Module.Import,
) struct { *std.Build.Step.Run, std.Build.LazyPath } {
    var run = b.addRunArtifact(b.addExecutable(.{
        .name = "build_rules",
        .root_module = b.createModule(.{
            .root_source_file = root_source_path,
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    }));

    const output = run.addOutputFileArg("rules.zig");
    for (rule_imports) |rule| run.addArg(rule.name);

    return .{ run, output };
}

fn createRulesModule(
    b: *std.Build,
    zlinter_import: std.Build.Module.Import,
    rule_imports: []const std.Build.Module.Import,
    build_rules_output: std.Build.LazyPath,
) error{OutOfMemory}!*std.Build.Module {
    const rules_imports = try std.mem.concat(
        b.allocator,
        std.Build.Module.Import,
        &.{
            &[1]std.Build.Module.Import{zlinter_import},
            rule_imports,
        },
    );
    defer b.allocator.free(rules_imports);

    return b.createModule(.{
        .root_source_file = build_rules_output,
        .imports = rules_imports,
    });
}

fn addOptionalFileArg(b: *std.Build, step: *std.Build.Step.Run, raw_path: []const u8) void {
    var path = b.path(raw_path);
    const relative_path = path.getPath3(b, &step.step).sub_path;
    const exists = if (std.fs.cwd().access(relative_path, .{})) true else |e| e != error.FileNotFound;
    if (exists) {
        step.addFileArg(path);
    } else {
        step.addArg(relative_path);
    }
}
