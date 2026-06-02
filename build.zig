const @"build.zig" = @This();

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
    require_labeled_continue,
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
    no_redundant_comptime,
    require_exhaustive_enum_switch,
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
    path: std.Build.LazyPath,
};

/// Represents something that should be excluded from linting.
const LintExcludeSource = union(enum) {
    path: std.Build.LazyPath,
};

const StepBuilder = struct {
    rules: std.ArrayList(BuiltRule),
    include: std.ArrayList(LintIncludeSource),
    exclude: std.ArrayList(LintExcludeSource),
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

    /// Adds a source path to be linted.
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
    const io = b.graph.io;

    const zls_stub_module = b.createModule(.{
        .root_source_file = b.path("src/lib/zls_stub.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zlinter_lib_module = b.addModule("zlinter", .{
        .root_source_file = b.path("src/lib/zlinter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "zls",
                .module = zls_stub_module,
            },
        },
    });

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
    const builtin_rule_names = comptime std.meta.fieldNames(BuiltinLintRule);
    // zlinter-disable-next-line no_undefined - immediately set in inline loop
    var rules: [builtin_rule_names.len]BuiltRule = undefined;
    // zlinter-disable-next-line no_undefined - immediately set in inline loop
    var rule_imports: [builtin_rule_names.len]std.Build.Module.Import = undefined;

    inline for (builtin_rule_names, 0..) |enum_type_name, i| {
        const rule_module = b.createModule(.{
            .root_source_file = b.path("src/rules/" ++ enum_type_name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{zlinter_import},
        });

        // Rule as import:
        rule_imports[i] = .{
            .name = enum_type_name,
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
    const kcov_bin = b.findProgram(
        .{ .names = &.{"kcov"} },
    ) orelse "kcov";
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
    // TODO: #149 - Look into adding this back
    // addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/src"), .none) catch @panic("OOM");
    // addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/test_cases"), .none) catch @panic("OOM");
    // addWatchInput(b, &run_integration_tests.step, b.path("./src"), .none) catch @panic("OOM");
    // addWatchInput(b, &run_integration_tests.step, b.path("./integration_tests/build.zig"), .none) catch @panic("OOM");
    // addWatchInput(b, &run_integration_tests.step, b.path("./build_rules.zig"), .none) catch @panic("OOM");

    const integration_test_step = b.step("integration-test", "Run integration tests");
    integration_test_step.dependOn(&run_integration_tests.step);

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
        readHtmlTemplate(b, "website/explorer/index.template.html") catch @panic("OOM"),
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
        var include = std.ArrayList(LintIncludeSource).empty;
        var exclude = std.ArrayList(LintExcludeSource).empty;

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
                buildBuiltinRule(b, .require_labeled_continue, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{ .severity = .warning }),
                buildBuiltinRule(b, .require_errdefer_dealloc, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .require_braces, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .require_doc_comment, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .require_exhaustive_enum_switch, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{ .severity = .warning }),
                buildBuiltinRule(b, .no_hidden_allocations, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_swallow_error, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_comment_out_code, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_todo, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_panic, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
                buildBuiltinRule(b, .no_redundant_comptime, .{ .target = target, .optimize = optimize, .zlinter_import = zlinter_import }, .{}),
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
                .optimize = .Debug,
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
        const step = &doc_build_run.step;

        var install_step = b.addInstallFileWithDir(
            doc_build_run.addOutputFileArg("RULES.md"),
            .{ .custom = "../" },
            "RULES.md",
        );
        install_step.step.dependOn(step);

        // TODO: #149 - bring this back?
        // const rules_lazy_path = b.path("src/rules");
        // _ = step.addDirectoryWatchInput(rules_lazy_path) catch @panic("OOM");

        var rules_dir = b.root.openDir(
            io,
            "src/rules",
            .{ .iterate = true },
        ) catch @panic("unable to open rules/ directory");
        defer rules_dir.close(io);
        {
            var it = rules_dir.walk(b.allocator) catch @panic("OOM");
            while (it.next(io) catch @panic("OOM")) |entry| {
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

    var run = b.addRunArtifact(zlinter_exe);
    run.addPassthruArgs();

    run.addArg("--zig_exe");
    run.addFileArg(.zig_exe);

    run.addArg("--global_cache_root");
    run.addFileArg(.cache_root);

    run.addArg("--zig_lib_directory");
    run.addFileArg(.zig_lib);

    var include_paths: std.ArrayList([]const u8) = .empty;
    defer include_paths.deinit(b.allocator);

    var exclude_paths: std.ArrayList([]const u8) = .empty;
    defer exclude_paths.deinit(b.allocator);

    for (include) |source| {
        switch (source) {
            .path => |path| {
                switch (path) {
                    .src_path => |source_path| {
                        include_paths.append(b.allocator, source_path.sub_path) catch @panic("OOM");
                    },
                    .cwd_relative => |relative_path| {
                        include_paths.append(b.allocator, relative_path) catch @panic("OOM");
                    },
                    else => @panic("Unsupported lazy path"),
                }
            },
        }
    }

    for (exclude) |source| {
        switch (source) {
            .path => |path| {
                switch (path) {
                    .src_path => |source_path| {
                        exclude_paths.append(b.allocator, source_path.sub_path) catch @panic("OOM");
                    },
                    .cwd_relative => |relative_path| {
                        exclude_paths.append(b.allocator, relative_path) catch @panic("OOM");
                    },
                    else => @panic("Unsupported lazy path"),
                }
            },
        }
    }

    const build_info_zon_bytes: []const u8 = toZonString(BuildInfo{
        .include_paths = if (include_paths.items.len > 0) include_paths.items else null,
        .exclude_paths = if (exclude_paths.items.len > 0) exclude_paths.items else null,
    }, b.allocator);

    run.addArg("--stdin");

    var buff = std.Io.Writer.Allocating.init(b.allocator);

    // TODO: #149 - Use u32 instead of usize and try and avoid build_info_zon_bytes written twice
    buff.writer.writeInt(usize, build_info_zon_bytes.len, .little) catch @panic("stdin write failed");
    buff.writer.writeAll(build_info_zon_bytes) catch @panic("stdin write failed");

    run.setStdIn(.{ .bytes = buff.written() });

    return &run.step;
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
    var rule_imports = std.ArrayList(std.Build.Module.Import).empty;
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

fn readHtmlTemplate(b: *std.Build, path: []const u8) ![]const u8 {
    const rules_path = try b.root.join(b.allocator, path);

    const io = b.graph.io;
    var file = try rules_path.root_dir.handle.openFile(io, rules_path.subPathOrDot(), .{});
    defer file.close(io);

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

    const timestamp = std.Io.Clock.real.now(b.graph.io);
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
    dir: std.Io.Dir,

    pub fn init(io: std.Io, buff: *[std.fs.max_path_bytes]u8) BuildCwd {
        const size = std.process.currentPath(io, buff) catch unreachable;
        return .{
            .dir = std.Io.Dir.cwd(),
            .path = buff[0..size],
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
                b.graph.cache.cwd,
                &b.graph.environ_map,
                self.path,
                to,
            ) catch |e|
                switch (e) {
                    error.OutOfMemory => @panic("OOM"),
                };
            errdefer b.allocator.free(relative);

            if (relative.len != 0 and isReadable(b, &self.dir, relative)) {
                return b.path(relative);
            } else {
                b.allocator.free(relative);
                return null;
            }
        } else {
            if (isReadable(b, &self.dir, to)) {
                return b.path(b.dupe(to));
            }
        }
        return null;
    }

    fn isReadable(b: *std.Build, from: *const std.Io.Dir, sub_path: []const u8) bool {
        _ = from.access(
            b.graph.io,
            sub_path,
            .{ .read = true },
        ) catch return false;
        return true;
    }
};

const BuildInfo = @import("src/lib/BuildInfo.zig");
const std = @import("std");
const isLintableFilePath = @import("src/lib/files.zig").isLintableFilePath;
const zig_version_string = @import("builtin").zig_version_string;
pub const version = @import("./src/lib/version.zig");
