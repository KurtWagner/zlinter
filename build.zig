const @"build.zig" = @This();

const zls_version: []const u8 = switch (version.zig) {
    .@"0.16" => "0.16.0-dev",
    .@"0.15" => "0.15.0",
    .@"0.14" => "0.14.0",
};

pub const BuiltinLintRule = enum {
    field_naming,
    field_ordering,
    declaration_naming,
    function_naming,
    file_naming,
    import_ordering,
    no_unused,
    no_deprecated,
    no_inferred_error_unions,
    no_orelse_unreachable,
    no_undefined,
    no_literal_only_bool_expression,
    no_hidden_allocations,
    switch_case_ordering,
    max_positional_args,
    no_comment_out_code,
    no_todo,
    no_literal_args,
    no_swallow_error,
    no_panic,
    require_braces,
    require_doc_comment,
    require_errdefer_dealloc,
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

    /// You may configure depending on the size of your project and how it's run
    ///
    /// Release optimisations cost more upfront but once cached will offer faster
    /// iterations. Typically preferred for development cycles, especially if
    /// running with `--watch`.
    ///
    /// Debug optimisation is cheaper up-front but slower to run, which may make
    /// it more suitable for average sized projects in cold environments (e.g.,
    /// cacheless CI environments).
    ///
    /// If your project is tiny, then it's fine to not think too much about this
    /// and to simply leave on debug.
    optimize: std.builtin.OptimizeMode = .Debug,
};

/// Creater a step builder for zlinter
pub fn builder(b: *std.Build, options: BuilderOptions) StepBuilder {
    return .{
        .rules = .empty,
        .include_paths = .empty,
        .exclude_paths = .empty,
        .b = b,
        .optimize = options.optimize,
        .target = options.target orelse b.graph.host,
    };
}

const StepBuilder = struct {
    rules: shims.ArrayList(BuiltRule),
    include_paths: shims.ArrayList(std.Build.LazyPath),
    exclude_paths: shims.ArrayList(std.Build.LazyPath),
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,

    pub fn addRule(
        self: *StepBuilder,
        comptime source: BuildRuleSource,
        config: anytype,
    ) void {
        self.rules.append(
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
        ) catch @panic("OOM");
    }

    /// Set the paths to include or exclude when running the linter.
    ///
    /// Include defaults to the current working directory. `zig-out` and
    /// `.zig-cache` are always excluded - you don't need to explicitly include
    /// them if setting exclude paths.
    pub fn addPaths(
        self: *StepBuilder,
        paths: struct {
            include: ?[]const std.Build.LazyPath = null,
            exclude: ?[]const std.Build.LazyPath = null,
        },
    ) void {
        if (paths.include) |includes|
            for (includes) |path| self.include_paths.append(self.b.allocator, path) catch @panic("OOM");
        if (paths.exclude) |excludes|
            for (excludes) |path| self.exclude_paths.append(self.b.allocator, path) catch @panic("OOM");
    }

    /// Returns a build step and cleans itself up.
    pub fn build(self: *StepBuilder) *std.Build.Step {
        defer self.deinit();

        return buildStep(
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
                .include_paths = self.include_paths,
                .exclude_paths = self.exclude_paths,
            },
        );
    }

    fn deinit(self: *StepBuilder) void {
        self.include_paths.deinit(self.b.allocator);
        self.exclude_paths.deinit(self.b.allocator);
        for (self.rules.items) |*r| r.deinit(self.b.allocator);
        self.* = undefined;
    }
};

/// zlinters own build file for running its tests and itself on itself
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const coverage = b.option(bool, "coverage", "Generate a coverage report with kcov") orelse false;

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
    if (version.zig == .@"0.15" and target.result.os.tag == .windows) {
        zlinter_lib_module.linkSystemLibrary("advapi32", .{});
    }

    const zlinter_import = std.Build.Module.Import{
        .name = "zlinter",
        .module = zlinter_lib_module,
    };

    const unit_tests_exe = b.addTest(.{ .root_module = zlinter_lib_module });
    const run_unit_tests = b.addRunArtifact(unit_tests_exe);

    // --------------------------------------------------------------------
    // Generate dynamic rules list and configs
    // --------------------------------------------------------------------
    // zlinter-disable-next-line no_undefined - immediately set in inline loop
    var rules: [@typeInfo(BuiltinLintRule).@"enum".fields.len]BuiltRule = undefined;
    // zlinter-disable-next-line no_undefined - immediately set in inline loop
    var rule_imports: [@typeInfo(BuiltinLintRule).@"enum".fields.len]std.Build.Module.Import = undefined;

    inline for (std.meta.fields(BuiltinLintRule), 0..) |enum_type, i| {
        const rule_module = b.createModule(.{
            .root_source_file = b.path("src/rules/" ++ enum_type.name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{zlinter_import},
        });

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
    const kcov_bin = b.findProgram(&.{"kcov"}, &.{}) catch "kcov";
    const merge_coverage = std.Build.Step.Run.create(b, "Unit test coverage");
    merge_coverage.rename_step_with_output_arg = false;
    merge_coverage.addArgs(&.{ kcov_bin, "--merge" });
    const merged_coverage_output = merge_coverage.addOutputDirectoryArg("merged/");

    const install_coverage = b.addInstallDirectory(.{
        .source_dir = merged_coverage_output,
        .install_dir = .{ .custom = "coverage" },
        .install_subdir = "",
    });
    install_coverage.step.dependOn(&merge_coverage.step);

    const run_integration_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test" });
    run_integration_tests.setCwd(b.path("./integration_tests"));

    // Add directory and file inputs to ensure that we can watch and re-run tests
    // as these can't be resolved magicaly through the system call.
    addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/src"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/test_cases"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./src"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/build.zig"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./build_rules.zig"), .none) catch @panic("OOM");

    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const unit_test_step = b.step("unit-test", "Run unit tests");
    if (coverage) {
        const cover_run = std.Build.Step.Run.create(b, "Unit test coverage");
        cover_run.addArgs(&.{ kcov_bin, "--clean", "--collect-only" });
        cover_run.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
        merge_coverage.addDirectoryArg(cover_run.addOutputDirectoryArg("unit_test_coverage"));
        cover_run.addArtifactArg(unit_tests_exe);

        unit_test_step.dependOn(&install_coverage.step);
    } else {
        unit_test_step.dependOn(&run_unit_tests.step);
    }

    for (rule_imports) |rule_import| {
        const test_rule_exe = b.addTest(.{
            .name = b.fmt("{s}_unit_test_coverage", .{rule_import.name}),
            .root_module = rule_import.module,
        });
        const run_test_rule_exe = b.addRunArtifact(test_rule_exe);

        if (coverage) {
            const cover_run = std.Build.Step.Run.create(b, "Unit test coverage");
            cover_run.addArgs(&.{ kcov_bin, "--clean", "--collect-only" });
            cover_run.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
            merge_coverage.addDirectoryArg(cover_run.addOutputDirectoryArg(test_rule_exe.name));
            cover_run.addArtifactArg(test_rule_exe);

            unit_test_step.dependOn(&install_coverage.step);
        } else {
            unit_test_step.dependOn(&run_test_rule_exe.step);
        }
    }

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(unit_test_step);
    test_step.dependOn(integration_test_step);

    // ------------------------------------------------------------------------
    // zig build website
    // ------------------------------------------------------------------------
    const build_website = b.step("website", "Build website.");
    const wasm_exe = b.addExecutable(.{
        .name = "wasm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/exe/wasm.zig"),
            .imports = &.{zlinter_import},
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm_exe.entry = .disabled;
    wasm_exe.rdynamic = true;
    const install_wasm_step = b.addInstallArtifact(wasm_exe, .{ .dest_dir = .{
        .override = .{ .custom = "website/explorer/" },
    } });
    build_website.dependOn(&install_wasm_step.step);
    const install_public_step = b.addInstallDirectory(.{
        .source_dir = b.path("website"),
        .install_dir = .prefix,
        .install_subdir = "website",
    });

    const write_file = b.addWriteFiles();
    const write_index_html = write_file.add(
        "website/explorer/index.html",
        readHtmlTemplate(b, b.path("website/explorer/index.template.html")) catch @panic("OOM"),
    );
    const install_index_html = b.addInstallFile(
        write_index_html,
        "website/explorer/index.html",
    );

    build_website.dependOn(&install_index_html.step);
    build_website.dependOn(&install_public_step.step);

    // ------------------------------------------------------------------------
    // zig build lint
    // ------------------------------------------------------------------------

    const lint_cmd = b.step("lint", "Lint the linters own source code.");
    lint_cmd.dependOn(step: {
        var exclude_paths = shims.ArrayList(std.Build.LazyPath).empty;
        defer exclude_paths.deinit(b.allocator);

        exclude_paths.append(b.allocator, b.path("integration_tests/test_cases")) catch @panic("OOM");
        exclude_paths.append(b.allocator, b.path("integration_tests/src/test_case_references.zig")) catch @panic("OOM");

        break :step buildStep(
            b,
            &.{
                buildBuiltinRule(b, .field_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .field_ordering, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .declaration_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .function_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .import_ordering, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .file_naming, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_unused, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .switch_case_ordering, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_deprecated, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_inferred_error_unions, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_orelse_unreachable, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_undefined, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_literal_only_bool_expression, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .require_braces, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .require_doc_comment, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .require_errdefer_dealloc, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_hidden_allocations, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_swallow_error, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_comment_out_code, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_todo, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_panic, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .max_positional_args, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(
                    b,
                    .no_literal_args,
                    .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import },
                    .{
                        .exclude_fn_names = &.{
                            "print",
                            "alloc",
                            "allocWithOptions",
                            "allocWithOptionsRetAddr",
                            "allocSentinel",
                            "alignedAlloc",
                            "allocAdvancedWithRetAddr",
                            "resize",
                            "realloc",
                            "reallocAdvanced",
                            "parseInt",
                            "debugPrintWithIndent",
                            "tokenLocation",
                            "expectEqual",
                            "renderLine",
                            "init",
                        },
                    },
                ),
            },
            .{
                .target = target,
                .optimize = optimize,
                .exclude_paths = exclude_paths,
                .zlinter = .{ .module = zlinter_lib_module },
            },
        );
    });

    // ------------------------------------------------------------------------
    // zig build docs
    // ------------------------------------------------------------------------
    const docs_cmd = b.step("docs", "Regenerate docs (should be run before every commit)");
    docs_cmd.dependOn(step: {
        const doc_build_run = b.addRunArtifact(b.addExecutable(.{
            .name = "build_docs",
            .root_module = b.createModule(.{
                .root_source_file = b.path("build_docs.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        }));
        var step = &doc_build_run.step;

        var install_step = b.addInstallFileWithDir(
            doc_build_run.addOutputFileArg("RULES.md"),
            .{ .custom = "../" },
            "RULES.md",
        );
        install_step.step.dependOn(step);

        const rules_lazy_path = b.path("src/rules");
        const rules_path = rules_lazy_path.getPath3(b, step);
        _ = step.addDirectoryWatchInput(rules_lazy_path) catch @panic("OOM");

        var rules_dir = rules_path.root_dir.handle.openDir(rules_path.subPathOrDot(), .{ .iterate = true }) catch @panic("unable to open rules/ directory");
        defer rules_dir.close();
        {
            var it = rules_dir.walk(b.allocator) catch @panic("OOM");
            while (it.next() catch @panic("OOM")) |entry| {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                doc_build_run.addFileArg(b.path(b.pathJoin(&.{ "src/rules", entry.path })));
            }
        }

        break :step &install_step.step;
    });
}

fn toZonString(val: anytype, allocator: std.mem.Allocator) []const u8 {
    var aw = std.io.Writer.Allocating.init(allocator);
    std.zon.stringify.serialize(val, .{}, &aw.writer) catch
        @panic("Invalid rule config");

    return aw.toOwnedSlice() catch @panic("OOM");
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
        include_paths: ?shims.ArrayList(std.Build.LazyPath) = null,
        exclude_paths: ?shims.ArrayList(std.Build.LazyPath) = null,
    },
) *std.Build.Step {
    const zlinter_lib_module: *std.Build.Module, const exe_file: std.Build.LazyPath, const build_rules_exe_file: std.Build.LazyPath = switch (options.zlinter) {
        .dependency => |d| .{ d.module("zlinter"), d.path("src/exe/run_linter.zig"), d.path("build_rules.zig") },
        .module => |m| .{ m, b.path("src/exe/run_linter.zig"), b.path("build_rules.zig") },
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
    if (version.zig == .@"0.15" and options.target.result.os.tag == .windows) {
        exe_module.linkSystemLibrary("advapi32", .{});
    }

    // --------------------------------------------------------------------
    // Generate dynamic rules and rules config
    // --------------------------------------------------------------------
    const rules_module = createRulesModule(
        b,
        zlinter_import,
        rules,
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
    const zlinter_exe = b.addExecutable(.{
        .name = "zlinter",
        .root_module = exe_module,
        // TODO: Look into why 0.15 is segfaulting on linux without this:
        .use_llvm = true,
    });

    const zlinter_run = ZlinterRun.create(b, zlinter_exe);

    if (b.args) |args| zlinter_run.addArgs(args);
    if (b.verbose) zlinter_run.addArgs(&.{"--verbose"});

    var include_path_added = false;
    if (options.include_paths) |include_paths| {
        include_path_added = include_paths.items.len > 0;
        for (include_paths.items) |path| {
            zlinter_run.addIncludePath(b, path);
        }
    }
    if (!include_path_added)
        zlinter_run.addIncludePath(b, b.path("./"));

    if (options.exclude_paths) |exclude_paths| {
        for (exclude_paths.items) |path|
            zlinter_run.addExcludePath(path.getPath3(b, &zlinter_run.step).subPathOrDot());
    }

    zlinter_run.addArgs(&.{ "--zig_exe", b.graph.zig_exe });
    if (b.graph.global_cache_root.path) |p|
        zlinter_run.addArgs(&.{ "--global_cache_root", p });

    if (b.graph.zig_lib_directory.path) |p|
        zlinter_run.addArgs(&.{ "--zig_lib_directory", p });

    return &zlinter_run.step;
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

fn addWatchInput(
    b: *std.Build,
    step: *std.Build.Step,
    file_or_dir: std.Build.LazyPath,
    kind: enum { none, lintable_file },
) !void {
    const src_dir_path = file_or_dir.getPath3(b, step);

    var src_dir = src_dir_path.root_dir.handle.openDir(
        src_dir_path.subPathOrDot(),
        .{ .iterate = true },
    ) catch |e| switch (e) {
        error.NotDir => {
            try step.addWatchInput(file_or_dir);
            return;
        },
        else => switch (version.zig) {
            .@"0.14" => @panic(b.fmt("Unable to open directory '{}': {s}", .{ src_dir_path, @errorName(e) })),
            .@"0.15", .@"0.16" => @panic(b.fmt("Unable to open directory '{f}': {t}", .{ src_dir_path, e })),
        },
    };
    defer src_dir.close();

    const needs_dir_derived = try step.addDirectoryWatchInput(file_or_dir);

    var it = try src_dir.walk(b.allocator);
    defer it.deinit();

    while (try it.next()) |entry| {
        switch (entry.kind) {
            .directory => if (needs_dir_derived) {
                const entry_path = try src_dir_path.join(b.allocator, entry.path);
                try step.addDirectoryWatchInputFromPath(entry_path);
            },
            .file => {
                const entry_path = try src_dir_path.joinString(b.allocator, entry.path);
                defer b.allocator.free(entry_path);

                if (kind != .lintable_file or isLintableFilePath(entry_path) catch false) {
                    try step.addWatchInput(try file_or_dir.join(b.allocator, entry.path));
                }
            },
            else => continue,
        }
    }
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
            .zon_config_str = toZonString(config, b.allocator),
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
                    .root_source_file = if (options.zlinter_dependency) |d|
                        d.path("src/rules/" ++ @tagName(inline_rule) ++ ".zig")
                    else
                        b.path("src/rules/" ++ @tagName(inline_rule) ++ ".zig"),
                    .target = options.target,
                    .optimize = options.optimize,
                    .imports = &.{options.zlinter_import},
                }),
            },
            .zon_config_str = toZonString(config, b.allocator),
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
    for (rules) |rule|
        run.addArg(rule.import.name);

    return output;
}

fn createRulesModule(
    b: *std.Build,
    zlinter_import: std.Build.Module.Import,
    rules: []const BuiltRule,
    build_rules_output: std.Build.LazyPath,
) *std.Build.Module {
    var rule_imports = std.ArrayListUnmanaged(std.Build.Module.Import).empty;
    for (rules) |r| rule_imports.append(b.allocator, r.import) catch @panic("OOM");
    defer rule_imports.deinit(b.allocator);

    const rules_imports = std.mem.concat(
        b.allocator,
        std.Build.Module.Import,
        &.{
            &[1]std.Build.Module.Import{zlinter_import},
            rule_imports.toOwnedSlice(b.allocator) catch @panic("OOM"),
        },
    ) catch @panic("OOM");
    defer b.allocator.free(rules_imports);

    const module = b.createModule(.{
        .root_source_file = build_rules_output,
        .imports = rules_imports,
    });

    for (rules) |rule| {
        const wf = b.addWriteFiles();
        const import_name = b.fmt("{s}.zon", .{rule.import.name});
        const path = wf.add(import_name, rule.zon_config_str);

        module.addImport(
            import_name,
            b.createModule(.{ .root_source_file = path }),
        );
    }

    return module;
}

const ZlinterRun = struct {
    step: std.Build.Step,

    /// CLI arguments to be passed to zlinter when executed
    argv: shims.ArrayList(Arg),

    /// Include paths configured within the build file.
    include_paths: shims.ArrayList([]const u8),

    /// Exclude paths confiured within the build file.
    exclude_paths: shims.ArrayList([]const u8),

    const Arg = union(enum) {
        artifact: *std.Build.Step.Compile,
        bytes: []const u8,
    };

    pub fn create(owner: *std.Build, exe: *std.Build.Step.Compile) *ZlinterRun {
        const arena = owner.allocator;

        const self = arena.create(ZlinterRun) catch @panic("OOM");
        self.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "Run zlinter",
                .owner = owner,
                .makeFn = make,
            }),
            .argv = .empty,
            .exclude_paths = .empty,
            .include_paths = .empty,
        };

        self.argv.append(arena, .{ .artifact = exe }) catch @panic("OOM");

        const bin_file = exe.getEmittedBin();
        bin_file.addStepDependencies(&self.step);

        return self;
    }

    pub fn addArgs(run: *ZlinterRun, args: []const []const u8) void {
        const b = run.step.owner;
        for (args) |arg|
            run.argv.append(b.allocator, .{ .bytes = b.dupe(arg) }) catch @panic("OOM");
    }

    pub fn addIncludePath(run: *ZlinterRun, owner: *std.Build, path: std.Build.LazyPath) void {
        addWatchInput(owner, &run.step, path, .lintable_file) catch @panic("OOM");
        run.include_paths.append(run.step.owner.allocator, run.step.owner.dupe(path.getPath3(owner, &run.step).subPathOrDot())) catch @panic("OOM");
    }

    pub fn addExcludePath(run: *ZlinterRun, exclude_path: []const u8) void {
        run.exclude_paths.append(run.step.owner.allocator, run.step.owner.dupe(exclude_path)) catch @panic("OOM");
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const run: *ZlinterRun = @alignCast(@fieldParentPtr("step", step));
        const b = run.step.owner;
        const arena = b.allocator;

        const build_info_zon_bytes: []const u8 = toZonString(BuildInfo{
            .include_paths = if (run.include_paths.items.len > 0) run.include_paths.items else null,
            .exclude_paths = if (run.exclude_paths.items.len > 0) run.exclude_paths.items else null,
        }, b.allocator);

        const env_map = arena.create(std.process.EnvMap) catch @panic("OOM");
        env_map.* = std.process.getEnvMap(arena) catch @panic("unhandled error");

        var argv_list = shims.ArrayList([]const u8).initCapacity(
            arena,
            run.argv.items.len + 1,
        ) catch @panic("OOM");

        for (run.argv.items) |arg| {
            switch (arg) {
                .bytes => |bytes| {
                    try argv_list.append(arena, bytes);
                },
                .artifact => |artifact| {
                    if (artifact.rootModuleTarget().os.tag == .windows) {
                        // Windows doesn't have rpaths so add .dll search paths to PATH environment variable
                        const chase_dynamics = true;
                        const compiles = artifact.getCompileDependencies(chase_dynamics);
                        for (compiles) |compile| {
                            if (compile.root_module.resolved_target.?.result.os.tag == .windows) continue;
                            if (compile.isDynamicLibrary()) continue;

                            const search_path = std.fs.path.dirname(compile.getEmittedBin().getPath2(b, &run.step)).?;
                            const key = "PATH";
                            if (env_map.get(key)) |prev_path| {
                                env_map.put(key, b.fmt("{s}{c}{s}", .{
                                    prev_path,
                                    std.fs.path.delimiter,
                                    search_path,
                                })) catch @panic("OOM");
                            } else {
                                env_map.put(key, b.dupePath(search_path)) catch @panic("OOM");
                            }
                        }
                    }
                    const file_path = artifact.installed_path orelse artifact.generated_bin.?.path.?;
                    try argv_list.append(arena, b.dupe(file_path));
                },
            }
        }

        // We're always sending "build_info_zon_bytes" in stdin
        argv_list.append(arena, "--stdin") catch @panic("OOM");

        if (!std.process.can_spawn) {
            return run.step.fail("Host cannot spawn zlinter:\n\t{s}", .{
                std.Build.Step.allocPrintCmd(
                    arena,
                    b.build_root.path,
                    argv_list.items,
                ) catch @panic("OOM"),
            });
        }

        if (b.verbose) {
            std.debug.print("zlinter command:\n\t{s}\n", .{
                std.Build.Step.allocPrintCmd(
                    arena,
                    b.build_root.path,
                    argv_list.items,
                ) catch @panic("OOM"),
            });
        }

        var child = std.process.Child.init(argv_list.items, arena);
        child.cwd = b.build_root.path;
        child.cwd_dir = b.build_root.handle;
        child.env_map = env_map;
        // As we're using stdout and stderr inherit we don't want to update
        // parent of childs progress (i.e commented out as deliberately not set)
        // child.progress_node = options.progress_node;
        child.request_resource_usage_statistics = true;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.stdin_behavior = .Pipe; // Otherwise, `.Ignore` if not sending stdin

        var timer = try std.time.Timer.start();

        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();

        child.spawn() catch |err| {
            return run.step.fail("Unable to spawn zlinter: {s}", .{@errorName(err)});
        };
        errdefer _ = child.kill() catch {};

        {
            if (b.verbose)
                std.debug.print("Writing stdin: '{s}'\n", .{build_info_zon_bytes});

            var stdin_file = child.stdin.?;
            switch (version.zig) {
                .@"0.14" => {
                    var writer = stdin_file.writer();
                    writer.writeInt(usize, build_info_zon_bytes.len, .little) catch @panic("stdin write failed");
                    writer.writeAll(build_info_zon_bytes) catch @panic("stdin write failed");
                },
                .@"0.15", .@"0.16" => {
                    var buffer: [1024]u8 = undefined;
                    var writer = stdin_file.writer(&buffer);
                    writer.interface.writeInt(usize, build_info_zon_bytes.len, .little) catch @panic("stdin write failed");
                    writer.interface.writeAll(build_info_zon_bytes) catch @panic("stdin write failed");
                    writer.interface.flush() catch @panic("Flush failed");
                },
            }
        }

        const term = try child.wait();

        step.result_duration_ns = timer.read();
        step.result_peak_rss = child.resource_usage_statistics.getMaxRss() orelse 0;
        step.test_results = .{};

        switch (term) {
            .Exited => |code| {
                // These codes are defined in run_linter.zig
                const success = 0;
                const lint_error = 2;
                const usage_error = 3;
                if (code == lint_error) {
                    return step.fail("zlinter detected issues", .{});
                } else if (code == usage_error) {
                    return step.fail("zlinter usage error", .{});
                } else if (code != success) {
                    return step.fail("zlinter command crashed:\n\t{s}", .{
                        std.Build.Step.allocPrintCmd(
                            arena,
                            b.build_root.path,
                            argv_list.items,
                        ) catch @panic("OOM"),
                    });
                }
            },
            .Signal, .Stopped, .Unknown => {
                return step.fail("zlinter was terminated unexpectedly:\n\t{s}", .{
                    std.Build.Step.allocPrintCmd(
                        arena,
                        b.build_root.path,
                        argv_list.items,
                    ) catch @panic("OOM"),
                });
            },
        }
    }
};

fn readHtmlTemplate(b: *std.Build, path: std.Build.LazyPath) ![]const u8 {
    const rules_path = path.getPath3(b, null);

    var file = try rules_path.root_dir.handle.openFile(rules_path.subPathOrDot(), .{});
    defer file.close();

    const max_bytes = 128 * 1024;
    const bytes = try file.readToEndAlloc(b.allocator, max_bytes);
    defer b.allocator.free(bytes);

    const replacement = b.fmt("{d}", .{std.time.milliTimestamp()});
    const needle = "{{build_timestamp}}";

    const buffer = try b.allocator.alloc(u8, std.mem.replacementSize(
        u8,
        bytes,
        needle,
        replacement,
    ));
    errdefer b.allocator.free(buffer);

    const replacements = std.mem.replace(
        u8,
        bytes,
        needle,
        replacement,
        buffer,
    );
    if (replacements == 0) @panic("Failed to replace template timestamps");
    return buffer;
}

const BuildInfo = @import("src/lib/BuildInfo.zig");
const std = @import("std");
const isLintableFilePath = @import("src/lib/files.zig").isLintableFilePath;
const shims = @import("src/lib/shims.zig");

pub const version = @import("./src/lib/version.zig");
