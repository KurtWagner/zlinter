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
    no_empty_block,
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

const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const BuilderOptions = struct {
    /// You should never need to set this. Defaults to native host.
    target: ?std.Build.ResolvedTarget = null,

    /// Optimisation to build zlinter at.
    ///
    /// `.Debug` is cheaper up-front but much slower to run. Only use
    /// `.Debug` for linter development purposes.
    ///
    /// For enormous projects consider using `.ReleaseFast`.
    optimize: std.builtin.OptimizeMode = .ReleaseSafe,
};

/// Create a step builder for zlinter
pub fn builder(b: *std.Build, options: BuilderOptions) StepBuilder {
    return .{
        .rules = .empty,
        .exclude = .empty,
        .include = .empty,
        .options = .{
            .optimize = options.optimize,
            .target = options.target orelse b.graph.host,
        },
        .b = b,
    };
}

/// Represents something that should be linted.
const LintIncludeSource = union(enum) {
    /// e.g., library or executable.
    compiled_unit: struct {
        compile_step: *std.Build.Step.Compile,
    },
    path: std.Build.LazyPath,

    pub fn compiled(compile: *std.Build.Step.Compile) LintIncludeSource {
        return .{
            .compiled_unit = .{
                .compile_step = compile,
            },
        };
    }
};

/// Represents something that should be excluded from linting.
const LintExcludeSource = union(enum) {
    path: std.Build.LazyPath,
};

const StepBuilder = struct {
    rules: shims.ArrayList(BuiltRule),
    include: shims.ArrayList(LintIncludeSource),
    exclude: shims.ArrayList(LintExcludeSource),
    options: BuildOptions,
    b: *std.Build,

    pub fn addRule(
        self: *StepBuilder,
        comptime source: BuildRuleSource,
        config: anytype,
    ) void {
        const arena = self.b.allocator;

        self.rules.append(
            arena,
            buildRule(
                self.b,
                source,
                .{
                    .optimize = self.options.optimize,
                    .target = self.options.target,
                },
                config,
            ),
        ) catch @panic("OOM");
    }

    /// Adds a source to be linted (e.g., library, executable or path). Only
    /// inputs resolved to this source within the projects path will be linted.
    ///
    /// If no paths are given or resolved then it falls back to linting all
    /// zig source files under the current working directory.
    pub fn addSource(self: *StepBuilder, source: LintIncludeSource) void {
        const arena = self.b.allocator;
        self.include.append(arena, source) catch @panic("OOM");
    }

    /// Set the paths to include or exclude when running the linter.
    ///
    /// Unless a source is set, includes defaults to the current working
    /// directory.
    ///
    /// If a source is set then paths included here included in combination with
    /// the inputs resolved from the set source.
    ///
    /// `zig-out` and `.zig-cache` are always excluded - you don't need to
    /// explicitly include them if setting exclude paths.
    pub fn addPaths(
        self: *StepBuilder,
        paths: struct {
            include: ?[]const std.Build.LazyPath = null,
            exclude: ?[]const std.Build.LazyPath = null,
        },
    ) void {
        const arena = self.b.allocator;

        if (paths.include) |includes|
            for (includes) |path| self.include.append(arena, .{ .path = path }) catch @panic("OOM");
        if (paths.exclude) |excludes|
            for (excludes) |path| self.exclude.append(arena, .{ .path = path }) catch @panic("OOM");
    }

    pub fn build(self: *StepBuilder) *std.Build.Step {
        const b = self.b;

        return buildStep(
            b,
            self.rules.items,
            .{
                .dependency = b.dependencyFromBuildZig(
                    @"build.zig",
                    .{},
                ),
            },
            self.include.items,
            self.exclude.items,
            self.options,
        );
    }
};

/// zlinters own build file for running its tests and itself on itself
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_coverage = b.option(bool, "coverage", "Generate a coverage report with kcov");
    const test_focus_on_rule = b.option([]const u8, "test_focus_on_rule", "Only run integration tests for this rule");

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

    const unit_tests_exe = b.addTest(.{
        .root_module = zlinter_lib_module,
        .use_llvm = test_coverage,
    });

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
    if (test_focus_on_rule) |r| {
        run_integration_tests.addArg(b.fmt("-Dtest_focus_on_rule={s}", .{r}));
    }
    run_integration_tests.setCwd(b.path("./integration_tests"));
    run_integration_tests.has_side_effects = true;

    // Add directory and file inputs to ensure that we can watch and re-run tests
    // as these can't be resolved magicaly through the system call.
    addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/src"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/test_cases"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./src"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/build.zig"), .none) catch @panic("OOM");
    addWatchInput(b, &run_integration_tests.step, b.path("./build_rules.zig"), .none) catch @panic("OOM");

    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

    const run_integration_check = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "check-compiled-source" });
    run_integration_check.has_side_effects = true;
    run_integration_check.setCwd(b.path("./integration_tests"));
    run_integration_check.color = .disable;
    run_integration_check.expectExitCode(0);
    run_integration_check.expectStdOutEqual(std.fmt.comptimePrint(
        \\warning `@panic` forcibly stops the program at runtime and should be avoided [{s}:4:5] no_panic
        \\
        \\ 4 |     @panic("whoops");
        \\   |     ^^^^^^^^^^^^^^^^
        \\
        \\x 1 warnings
        \\
    , .{"src" ++ std.fs.path.sep_str ++ "check_compiled_source" ++ std.fs.path.sep_str ++ "used.zig"}));
    addWatchInput(b, &run_integration_check.step, b.path("./integration_tests/src/check_compiled_source"), .none) catch @panic("OOM");

    const integration_check_step = b.step("integration-check", "Run integration checks");
    integration_check_step.dependOn(&run_integration_check.step);

    const unit_test_step = b.step("unit-test", "Run unit tests");
    if (test_coverage orelse false) {
        const cover_run = std.Build.Step.Run.create(b, "Unit test coverage");
        cover_run.addArgs(&.{ kcov_bin, "--clean", "--collect-only" });
        cover_run.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
        merge_coverage.addDirectoryArg(cover_run.addOutputDirectoryArg("unit_test_coverage"));
        cover_run.addArtifactArg(unit_tests_exe);

        unit_test_step.dependOn(&install_coverage.step);
    } else {
        const run_unit_tests = b.addRunArtifact(unit_tests_exe);
        unit_test_step.dependOn(&run_unit_tests.step);
    }

    for (rule_imports) |rule_import| {
        const test_rule_exe = b.addTest(.{
            .name = b.fmt("{s}_unit_test_coverage", .{rule_import.name}),
            .root_module = rule_import.module,
            .use_llvm = test_coverage,
        });

        if (test_coverage orelse false) {
            const cover_run = std.Build.Step.Run.create(b, "Unit test coverage");
            cover_run.addArgs(&.{ kcov_bin, "--clean", "--collect-only" });
            cover_run.addPrefixedDirectoryArg("--include-pattern=", b.path("src"));
            merge_coverage.addDirectoryArg(cover_run.addOutputDirectoryArg(test_rule_exe.name));
            cover_run.addArtifactArg(test_rule_exe);

            unit_test_step.dependOn(&install_coverage.step);
        } else {
            const run_test_rule_exe = b.addRunArtifact(test_rule_exe);
            unit_test_step.dependOn(&run_test_rule_exe.step);
        }
    }

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(unit_test_step);
    test_step.dependOn(integration_test_step);
    test_step.dependOn(integration_check_step);

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
        var include = shims.ArrayList(LintIncludeSource).empty;
        include.append(b.allocator, .compiled(b.addLibrary(.{
            .name = "zlinter",
            .root_module = zlinter_lib_module,
        }))) catch @panic("OOM");

        var exclude = shims.ArrayList(LintExcludeSource).empty;

        // Also lint all files within project, not just those resolved to our compiled source.
        include.append(b.allocator, .{ .path = b.path("./") }) catch @panic("OOM");
        exclude.append(b.allocator, .{ .path = b.path("integration_tests/test_cases") }) catch @panic("OOM");
        exclude.append(b.allocator, .{ .path = b.path("integration_tests/src/test_case_references.zig") }) catch @panic("OOM");

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
                buildBuiltinRule(b, .no_empty_block, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
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
            .{ .module = zlinter_lib_module },
            include.items,
            exclude.items,
            .{
                .target = target,
                .optimize = .ReleaseSafe,
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
    var aw = std.Io.Writer.Allocating.init(allocator);
    std.zon.stringify.serialize(val, .{}, &aw.writer) catch
        @panic("Invalid rule config");

    return aw.toOwnedSlice() catch @panic("OOM");
}

fn buildStep(
    b: *std.Build,
    rules: []const BuiltRule,
    zlinter: union(enum) {
        dependency: *std.Build.Dependency,
        module: *std.Build.Module,
    },
    include: []const LintIncludeSource,
    exclude: []const LintExcludeSource,
    options: BuildOptions,
) *std.Build.Step {
    const zlinter_lib_module: *std.Build.Module, const exe_file: std.Build.LazyPath, const build_rules_exe_file: std.Build.LazyPath = switch (zlinter) {
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

    const zlinter_run = ZlinterRun.create(
        b,
        zlinter_exe,
        include,
        exclude,
    );

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
    var rule_imports = shims.ArrayList(std.Build.Module.Import).empty;
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

    /// Exclude paths confiured within the build file.
    exclude: []const LintExcludeSource,

    /// The sources to lint (e.g., an executable or library).
    include: []const LintIncludeSource,

    const Arg = union(enum) {
        artifact: *std.Build.Step.Compile,
        bytes: []const u8,
    };

    pub fn create(
        owner: *std.Build,
        exe: *std.Build.Step.Compile,
        include: []const LintIncludeSource,
        exclude: []const LintExcludeSource,
    ) *ZlinterRun {
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
            .exclude = exclude,
            .include = include,
        };

        self.argv.append(arena, .{ .artifact = exe }) catch @panic("OOM");

        if (owner.args) |args| self.addArgs(args);
        if (owner.verbose) self.addArgs(&.{"--verbose"});

        self.addArgs(&.{ "--zig_exe", owner.graph.zig_exe });
        if (owner.graph.global_cache_root.path) |p|
            self.addArgs(&.{ "--global_cache_root", p });

        if (owner.graph.zig_lib_directory.path) |p|
            self.addArgs(&.{ "--zig_lib_directory", p });

        const bin_file = exe.getEmittedBin();
        bin_file.addStepDependencies(&self.step);

        for (include) |s| {
            switch (s) {
                .compiled_unit => |info| self.step.dependOn(
                    &info.compile_step.step,
                ),
                .path => |path| addWatchInput(
                    owner,
                    &self.step,
                    path,
                    .lintable_file,
                ) catch @panic("OOM"),
            }
        }

        return self;
    }

    fn addArgs(run: *ZlinterRun, args: []const []const u8) void {
        const b = run.step.owner;
        for (args) |arg|
            run.argv.append(b.allocator, .{ .bytes = b.dupe(arg) }) catch @panic("OOM");
    }

    fn subPaths(
        step: *std.Build.Step,
        paths: []const std.Build.LazyPath,
    ) error{OutOfMemory}!?[]const []const u8 {
        if (paths.len == 0) return null;

        const b = step.owner;

        var list: shims.ArrayList([]const u8) = try .initCapacity(
            b.allocator,
            paths.len,
        );
        defer list.deinit(b.allocator);

        for (paths) |path| {
            list.appendAssumeCapacity(
                path.getPath3(b, step).subPathOrDot(),
            );
        }

        return try list.toOwnedSlice(b.allocator);
    }

    fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
        const run: *ZlinterRun = @alignCast(@fieldParentPtr("step", step));
        const b = run.step.owner;
        const arena = b.allocator;

        var cwd_buff: [std.fs.max_path_bytes]u8 = undefined;
        const cwd: BuildCwd = .init(&cwd_buff);

        var includes: shims.ArrayList(std.Build.LazyPath) = try .initCapacity(
            b.allocator,
            @max(1, run.include.len),
        );
        defer includes.deinit(b.allocator);

        for (run.include) |source| {
            switch (source) {
                .compiled_unit => |info| {
                    var exe = info.compile_step;

                    // TODO: Use graph for import map.
                    const graph = exe.root_module.getGraph();
                    _ = graph;

                    var inputs = exe.step.inputs;
                    std.debug.assert(inputs.populated());

                    var it = inputs.table.iterator();
                    while (it.next()) |entry| {
                        const p = entry.key_ptr.*;
                        sub_paths: for (entry.value_ptr.items) |sub_path| {
                            var buf: [std.fs.max_path_bytes]u8 = undefined;
                            const joined_path = if (p.sub_path.len == 0) sub_path else p: {
                                const fmt = "{s}" ++ std.fs.path.sep_str ++ "{s}";
                                break :p std.fmt.bufPrint(
                                    &buf,
                                    fmt,
                                    .{ p.sub_path, sub_path },
                                ) catch {
                                    std.debug.print(
                                        "Warning: Name too long - " ++ fmt,
                                        .{ p.sub_path, sub_path },
                                    );
                                    continue :sub_paths;
                                };
                            };
                            std.debug.assert(joined_path.len > 0);

                            if (!try isLintableFilePath(joined_path)) continue :sub_paths;

                            if (cwd.relativePath(b, joined_path)) |path| {
                                try includes.append(b.allocator, path);
                            }
                        }
                    }
                },
                .path => |path| try includes.append(
                    b.allocator,
                    path,
                ),
            }
        }
        if (includes.items.len == 0) {
            includes.appendAssumeCapacity(b.path("./"));
        }

        var excludes: shims.ArrayList(std.Build.LazyPath) = try .initCapacity(b.allocator, run.exclude.len);
        defer excludes.deinit(b.allocator);
        for (run.exclude) |exclude| {
            switch (exclude) {
                .path => |path| excludes.appendAssumeCapacity(path),
            }
        }

        const build_info_zon_bytes: []const u8 = toZonString(BuildInfo{
            .include_paths = try subPaths(&run.step, includes.items),
            .exclude_paths = try subPaths(&run.step, excludes.items),
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

                            const bin_path = compile.getEmittedBin().getPath3(b, &run.step);
                            const search_path = std.fs.path.dirname(b.pathResolve(&.{ bin_path.root_dir.path orelse ".", bin_path.sub_path })).?;
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

    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(b.graph.io, &file_buffer);

    var out: std.Io.Writer.Allocating = .init(b.allocator);
    defer out.deinit();

    var template_name_buffer: [32]u8 = undefined; // must be big enough for template names (e.g., build_template)
    var template_name: std.Io.Writer.Allocating = .initOwnedSlice(b.allocator, &template_name_buffer);
    defer template_name.deinit();

    if (file_reader.getSize()) |size| {
        try out.ensureTotalCapacity(size);
    } else |_| {
        // Ignore.
    }

    const timestamp = try std.Io.Clock.real.now(b.graph.io);
    const build_timestamp = b.fmt("{d}", .{@divTrunc(timestamp.nanoseconds, std.time.ns_per_ms)});
    const zig_version = zig_version_string;

    while (true) {
        if (file_reader.interface.streamDelimiter(&out.writer, '{')) |_| {
            file_reader.interface.toss(1); // Toss '{'

            if (file_reader.interface.streamDelimiter(&template_name.writer, '}')) |_| {
                defer template_name.clearRetainingCapacity();

                if (std.mem.eql(u8, template_name.written(), "zig_version")) {
                    try out.writer.writeAll(zig_version);
                } else if (std.mem.eql(u8, template_name.written(), "build_timestamp")) {
                    try out.writer.writeAll(build_timestamp);
                } else {
                    std.log.err("Unable to handle template: {s}", .{template_name.written()});
                    @panic("Invalid template");
                }
                file_reader.interface.toss(1); // Toss '}'
            } else |_| {
                @panic("Invalid template: Unable to find closing }");
            }
        } else |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        }
    }

    return try out.toOwnedSlice();
}

/// Normalised representation of the current working directory
const BuildCwd = struct {
    path: []const u8,
    dir: std.fs.Dir,

    pub fn init(buff: *[std.fs.max_path_bytes]u8) BuildCwd {
        return .{
            .dir = std.fs.cwd(),
            .path = std.process.getCwd(buff) catch unreachable,
        };
    }

    /// Returns a path relative to the current working directory or null if the
    /// path is not relative to the current working directory.
    ///
    /// If the path is a relative path, we check whether it exists with the
    /// current working directory.
    ///
    /// If the path is absolute, we check whether it resolves to a readable
    /// file within the current working directory.
    pub fn relativePath(
        self: *const BuildCwd,
        b: *std.Build,
        to: []const u8,
    ) ?std.Build.LazyPath {
        if (std.fs.path.isAbsolute(to)) {
            const relative = std.fs.path.relative(
                b.allocator,
                self.path,
                to,
            ) catch |e|
                switch (e) {
                    error.OutOfMemory => @panic("OOM"),
                    error.Unexpected,
                    error.CurrentWorkingDirectoryUnlinked,
                    => return null,
                };
            errdefer b.allocator.free(relative);

            if (relative.len != 0 and isReadable(&self.dir, relative)) {
                return b.path(relative);
            } else {
                b.allocator.free(relative);
                return null;
            }
        } else {
            if (isReadable(&self.dir, to)) {
                return b.path(b.dupe(to));
            }
        }
        return null;
    }

    fn isReadable(from: *const std.fs.Dir, sub_path: []const u8) bool {
        _ = from.access(
            sub_path,
            .{ .read = true },
        ) catch return false;
        return true;
    }
};

const BuildInfo = @import("src/lib/BuildInfo.zig");
const std = @import("std");
const isLintableFilePath = @import("src/lib/files.zig").isLintableFilePath;
const shims = @import("src/lib/shims.zig");
const zig_version_string = @import("builtin").zig_version_string;
pub const version = @import("./src/lib/version.zig");
