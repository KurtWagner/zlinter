const @"build.zig" = @This();

const zls_version: []const u8 = switch (version.zig) {
    .@"0.15" => "0.15.0-dev",
    .@"0.14" => "0.14.0",
};

pub const BuiltinLintRule = enum {
    no_unused,
    field_naming,
    declaration_naming,
    function_naming,
    file_naming,
    no_deprecation,
};

const BuildRuleSource = union(enum) {
    builtin: BuiltinLintRule,
    custom: struct {
        name: []const u8,
        path: []const u8,
    },
};

const BuiltRule = struct {
    import: std.Build.Module.Import,
    zon_config_str: []const u8,

    fn deinit(self: *BuiltRule, allocator: std.mem.Allocator) void {
        allocator.free(self.zon_config_str);
    }
};

pub const BuilderOptions = struct {
    /// You should never need to set this. Defaults to native host.
    target: ?std.Build.ResolvedTarget = null,

    /// You should never need to set this. Leave it to be managed by zlinter
    optimize: std.builtin.OptimizeMode = .Debug,
};

/// Creater a step builder for zlinter
pub fn builder(b: *std.Build, options: BuilderOptions) StepBuilder {
    return .{
        .rules = .empty,
        .b = b,
        .optimize = options.optimize,
        .target = options.target orelse b.graph.host,
    };
}

const StepBuilder = struct {
    rules: std.ArrayListUnmanaged(BuiltRule),
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    pub fn addRule(
        self: *StepBuilder,
        comptime source: BuildRuleSource,
        config: anytype,
    ) error{OutOfMemory}!void {
        try self.rules.append(
            self.b.allocator,
            buildRule(
                self.b,
                source,
                .{
                    .optimize = self.optimize,
                    .target = self.target,
                },
                config,
            ),
        );
    }

    /// Returns a build step and cleans itself up.
    pub fn build(self: *StepBuilder) BuildStepError!*std.Build.Step {
        defer self.deinit();

        return try buildStep(
            self.b,
            self.rules.items,
            .{
                .target = self.target,
                .optimize = self.optimize,
                .zlinter = .{
                    .dependency = self.b.dependencyFromBuildZig(
                        @"build.zig",
                        .{},
                    ),
                },
            },
        );
    }

    fn deinit(self: *StepBuilder) void {
        for (self.rules.items) |*r| r.deinit(self.b.allocator);
    }
};

pub const BuildStepError = error{
    OutOfMemory,
    InvalidConfig,
};

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
                .@"version-string" = zls_version,
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
    var rules: [@typeInfo(BuiltinLintRule).@"enum".fields.len]BuiltRule = undefined;
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
        rules[i] = .{
            .import = rule_imports[i],
            .zon_config_str = ".{}",
        };
    }

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
    lint_cmd.dependOn(try buildStep(
        b,
        &.{
            buildBuiltinRule(b, .no_unused, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
            buildBuiltinRule(b, .field_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
            buildBuiltinRule(b, .declaration_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
            buildBuiltinRule(b, .function_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
            buildBuiltinRule(b, .file_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
            buildBuiltinRule(b, .no_deprecation, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
        },
        .{
            .target = target,
            .optimize = optimize,
            .zlinter = .{ .module = zlinter_lib_module },
        },
    ));
}

fn toZonString(val: anytype, allocator: std.mem.Allocator) ![]const u8 {
    var zon = std.ArrayListUnmanaged(u8).empty;
    defer zon.deinit(allocator);

    try std.zon.stringify.serialize(val, .{}, zon.writer(allocator));

    return zon.toOwnedSlice(allocator);
}

fn buildStep(
    b: *std.Build,
    rules: []const BuiltRule,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        zlinter: union(enum) {
            dependency: *std.Build.Dependency,
            module: *std.Build.Module,
        },
    },
) BuildStepError!*std.Build.Step {
    const zlinter_lib_module: *std.Build.Module, const exe_file: std.Build.LazyPath, const build_rules_exe_file: std.Build.LazyPath, _ = switch (options.zlinter) {
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
    var rule_imports = std.ArrayListUnmanaged(std.Build.Module.Import).empty;
    for (rules) |r| try rule_imports.append(b.allocator, r.import);
    defer rule_imports.deinit(b.allocator);

    const rules_module = try createRulesModule(
        b,
        zlinter_import,
        rule_imports.items,
        addBuildRulesStep(
            b,
            build_rules_exe_file,
            rules,
        ),
    );
    exe_module.addImport("rules", rules_module);

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

fn buildRule(
    b: *std.Build,
    comptime source: BuildRuleSource,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    },
    config: anytype,
) BuiltRule {
    const zlinter_import = std.Build.Module.Import{
        .name = "zlinter",
        .module = b.dependencyFromBuildZig(@This(), .{}).module("zlinter"),
    };

    return switch (source) {
        .builtin => |builtin| buildBuiltinRule(
            b,
            builtin,
            .{
                .target = options.target,
                .optimize = options.optimize,
                .zlinter_dependency = b.dependencyFromBuildZig(@This(), .{}),
                .zlinter_import = zlinter_import,
            },
            config,
        ),
        .custom => |custom| .{
            .import = .{
                .name = checkNoNameCollision(custom.name),
                .module = b.createModule(.{
                    .root_source_file = b.path(custom.path),
                    .target = options.target,
                    .optimize = options.optimize,
                    .imports = &.{zlinter_import},
                }),
            },
            .zon_config_str = toZonString(config, b.allocator) catch @panic("Invalid Rule config"),
        },
    };
}

fn buildBuiltinRule(
    b: *std.Build,
    rule: BuiltinLintRule,
    options: struct {
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        zlinter_dependency: ?*std.Build.Dependency = null,
        zlinter_import: std.Build.Module.Import,
    },
    config: anytype,
) BuiltRule {
    return switch (rule) {
        inline else => |inline_rule| .{
            .import = .{
                .name = @tagName(inline_rule),
                .module = b.createModule(.{
                    .root_source_file = if (options.zlinter_dependency) |d| d.path("src/rules/" ++ @tagName(inline_rule) ++ ".zig") else b.path("src/rules/" ++ @tagName(inline_rule) ++ ".zig"),
                    .target = options.target,
                    .optimize = options.optimize,
                    .imports = &.{options.zlinter_import},
                }),
            },
            .zon_config_str = toZonString(config, b.allocator) catch @panic("Invalid rule config"),
        },
    };
}

fn addBuildRulesStep(
    b: *std.Build,
    root_source_path: std.Build.LazyPath,
    rules: []const BuiltRule,
) std.Build.LazyPath {
    var run = b.addRunArtifact(b.addExecutable(.{
        .name = "build_rules",
        .root_module = b.createModule(.{
            .root_source_file = root_source_path,
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    }));

    const output = run.addOutputFileArg("rules.zig");

    for (rules) |rule| {
        run.addArg(rule.import.name);
        run.addArg(rule.zon_config_str);
    }

    return output;
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

const std = @import("std");
const version = @import("./src/lib/version.zig");
