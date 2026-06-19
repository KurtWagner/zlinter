const default_formatter = zlinter.formatters.DefaultFormatter{};

pub const std_options: std.Options = .{
    .log_level = if (@import("zlinter_build_config").verbose)
        .info
    else
        .err,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.smp_allocator;

    var session_arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer session_arena_allocator.deinit();
    const session_arena = init.arena.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdin_buffer: [1024]u8 = undefined;

    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);

    var printer: *zlinter.rendering.Printer = zlinter.rendering.process_printer;
    printer.init(
        &stdout_writer.interface,
        &stderr_writer.interface,
        try .init(io, std.Io.File.stdout(), init.environ_map),
        false,
    );

    const args = args: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        break :args zlinter.Args.allocParse(
            try init.minimal.args.toSlice(arena.allocator()),
            &rules,
            session_arena,
            &stdin_reader.interface,
        ) catch |e| switch (e) {
            error.InvalidArgs => {
                zlinter.Args.printHelp(printer);
                return ExitCode.usage_error.int();
            },
            error.InvalidBuildConfig => return ExitCode.tool_error.int(),
            error.OutOfMemory => @panic("OOM"),
        };
    };

    // Technically a chicken and egg problem as you can't rely on verbose stdout
    // while parsing args, so this would probably be better as a build option
    // but for now this should be fine and keeps args together at runtime...
    printer.verbose = args.verbose;

    if (args.help) {
        zlinter.Args.printHelp(printer);
        return ExitCode.success.int();
    }

    if (args.unknown_args) |unknown_args| {
        for (unknown_args) |arg|
            printer.println(.err, "Unknown argument: {s}", .{arg});
        zlinter.Args.printHelp(printer);
        return ExitCode.usage_error.int();
    }

    var total_fixes: usize = 0;
    const result = result: {
        var remaining_fix_passes = @max(1, args.fix_passes);
        while (remaining_fix_passes > 0) {
            if (run(
                io,
                gpa,
                session_arena,
                args,
                printer,
            )) |r| {
                total_fixes += r.fixes_applied;
                if (r.fixes_applied == 0 or remaining_fix_passes == 1) {
                    break :result r;
                } else {
                    remaining_fix_passes -= 1;
                    printer.print(.out, "{s}{d} fix passes remaining{s}\n", .{
                        printer.tty.ansiOrEmpty(&.{.bold}),
                        remaining_fix_passes,
                        printer.tty.ansiOrEmpty(&.{.reset}),
                    });
                }
            } else |e| {
                printer.print(.err, "{s}Error:{s} {s}\n", .{
                    printer.tty.ansiOrEmpty(&.{ .bold, .red }),
                    @errorName(e),
                    printer.tty.ansiOrEmpty(&.{.reset}),
                });
                break :result RunResult.tool_error;
            }
        }
        unreachable;
    };
    if (total_fixes > 0) {
        printer.print(
            .out,
            "{s}Total of {d} issues fixed{s}\n",
            .{
                printer.tty.ansiOrEmpty(&.{ .bold, .underline }),
                total_fixes,
                printer.tty.ansiOrEmpty(&.{.reset}),
            },
        );
    }
    try printer.flush();

    return result.exit_code.int();
}

fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    session_arena: std.mem.Allocator,
    args: zlinter.Args,
    printer: *zlinter.rendering.Printer,
) !RunResult {
    var timer = Timer.createStarted(io);
    var total_timer = Timer.createStarted(io);

    // Key is index to `lint_files` and value are errors for the file.
    var file_lint_problems = std.array_hash_map.Auto(
        u32,
        []zlinter.results.LintResult,
    ).empty;

    // ------------------------------------------------------------------------
    // Resolve files then apply excludes and filters
    // ------------------------------------------------------------------------

    var dir = try std.Io.Dir.cwd().openDir(io, "./", .{ .iterate = true });
    defer dir.close(io);

    const cwd = try std.process.currentPathAlloc(io, session_arena);

    const lint_files = try zlinter.files.allocLintFiles(
        io,
        cwd,
        dir,
        // `--include` argument supersedes build defined includes and excludes
        args.include_paths orelse args.build_info.include_paths orelse null,
        session_arena,
    );

    if (try buildExcludesIndex(
        io,
        cwd,
        session_arena,
        dir,
        args,
    )) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = index.contains(file.abs_path);
    }

    if (try buildFilterIndex(
        io,
        cwd,
        session_arena,
        dir,
        args,
    )) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = !index.contains(file.abs_path);
    }

    printer.println(.verbose, "Resolving {d} files took: {d}ms", .{ lint_files.len, timer.lapMilliseconds() });

    try runLinterRules(
        io,
        session_arena,
        lint_files,
        printer,
        &timer,
        &file_lint_problems,
        args,
        cwd,
    );

    printer.printBanner(.verbose);
    printer.println(.verbose, "Linted {d} files", .{lint_files.len});
    printer.println(.verbose, "Took {d}ms", .{total_timer.lapMilliseconds()});
    printer.printBanner(.verbose);

    // ------------------------------------------------------------------------
    // Print out results:
    // ------------------------------------------------------------------------

    return if (args.fix)
        try runFixes(
            io,
            session_arena,
            gpa,
            cwd,
            lint_files,
            file_lint_problems,
            printer,
        )
    else
        try runFormatter(
            io,
            session_arena,
            cwd,
            file_lint_problems,
            printer.stdout.?,
            printer.tty,
            switch (args.format) {
                .default => &default_formatter.formatter,
            },
            args.quiet,
            args.max_warnings,
        );
}

fn runLinterRules(
    io: std.Io,
    session_arena: std.mem.Allocator,
    lint_files: []zlinter.files.LintFile,
    printer: *zlinter.rendering.Printer,
    timer: *Timer,
    file_lint_problems: *std.array_hash_map.Auto(u32, []zlinter.results.LintResult),
    args: zlinter.Args,
    cwd: []const u8,
) !void {
    const zig_exe = args.zig_exe;
    const zig_lib_directory = args.zig_lib_directory;

    var maybe_slowest_files = if (args.verbose) SlowestItemQueue.init(session_arena) else null;
    defer if (maybe_slowest_files) |*slowest_files| {
        defer slowest_files.deinit();
        slowest_files.unloadAndPrint("Files", printer);
    };

    var file_arena_allocator = std.heap.ArenaAllocator.init(session_arena);
    defer file_arena_allocator.deinit();
    const file_arena = file_arena_allocator.allocator();

    var maybe_rule_elapsed_times: ?[rules.len]usize = if (args.verbose)
        @splat(0)
    else
        null;
    defer if (maybe_rule_elapsed_times) |*rule_elapsed_times| {
        var item_timers = SlowestItemQueue.init(session_arena);
        defer item_timers.deinit();

        for (rule_elapsed_times, 0..) |elapsed_ns, rule_id| {
            item_timers.add(.{
                .name = rules[rule_id].rule_id,
                .elapsed_ns = elapsed_ns,
            });
        }
        item_timers.unloadAndPrint("Rules", printer);
    };

    var context: zlinter.session.LintContext = .{
        .io = io,
        .session_arena = session_arena,
        .zig_exe = zig_exe,
        .zig_lib_directory = zig_lib_directory,
        .cwd = cwd,
        .file_store = .init(session_arena),
        .module_store = .init(session_arena),
        .build_config_store = .init(session_arena),
        .type_store = .init(session_arena),
        .decl_store = .init(
            session_arena,
            io,
            zig_lib_directory,
        ),
    };
    try context.init(args.compile_names);

    var enabled_rules = enabledRules(args.rules);

    var rule_configs: [rules.len]*anyopaque = undefined;
    {
        var rule_it = enabled_rules.iterator(.{ .direction = .forward, .kind = .set });
        while (rule_it.next()) |rule_index| {
            rule_configs[rule_index] = config: {
                if (args.rule_config_overrides) |rule_config_overrides| {
                    if (rule_config_overrides.get(rules[rule_index].rule_id)) |zon_path| {
                        inline for (0..rules_configs_types.len) |i| {
                            if (i == rule_index) {
                                const config = try session_arena.create(rules_configs_types[i]);

                                var diagnostics: zlinter.zon.Diagnostics = .{};

                                config.* = zlinter.zon.parseFileAlloc(
                                    rules_configs_types[i],
                                    std.Io.Dir.cwd(),
                                    zon_path,
                                    &diagnostics,
                                    io,
                                    session_arena,
                                ) catch |e| {
                                    switch (e) {
                                        error.ParseZon => {
                                            std.log.err("Failed to parse rule config: {f}", .{diagnostics});
                                        },
                                        else => {},
                                    }
                                    return e;
                                };
                                break :config config;
                            }
                        }
                        unreachable;
                    }
                }
                break :config rules_configs[rule_index];
            };
        }
    }

    files: for (lint_files, 0..) |lint_file, i| {
        defer _ = file_arena_allocator.reset(.retain_capacity);

        const cwd_rel_path = try allocCwdRelPath(
            file_arena,
            cwd,
            lint_file.abs_path,
        );

        if (lint_file.excluded) {
            printer.println(.verbose, "[{d}/{d}] Excluding: {s}", .{ i + 1, lint_files.len, cwd_rel_path });
            continue :files;
        }
        printer.println(.verbose, "[{d}/{d}] Linting: {s}", .{ i + 1, lint_files.len, cwd_rel_path });

        const file_id = context.resolveFile(lint_file.abs_path) catch |e| {
            printer.println(.err, "Unable to open file: {s} ({s})", .{ cwd_rel_path, @errorName(e) });
            continue :files;
        };
        const file_abs_path = context.file_store.fileAbsPath(file_id);

        var rule_timer = Timer.createStarted(io);
        defer {
            const ns = rule_timer.lapNanoseconds();
            printer.println(.verbose, "  - Total elapsed {d}ms", .{ns / std.time.ns_per_ms});
            if (maybe_slowest_files) |*slowest_files| {
                slowest_files.add(.{
                    .name = cwd_rel_path,
                    .elapsed_ns = ns,
                });
            }
        }

        var doc: zlinter.session.LintDocument = undefined;
        context.initDocument(file_id, file_arena, &doc) catch |e| {
            printer.println(.err, "Unable to open file: {s} ({s})", .{ cwd_rel_path, @errorName(e) });
            continue :files;
        };

        printer.println(.verbose, "  - Load document: {d}ms", .{timer.lapMilliseconds()});
        const tree = doc.tree(&context);
        printer.println(.verbose, "    - {d} bytes", .{tree.source.len});
        printer.println(.verbose, "    - {d} nodes", .{tree.nodes.len});
        printer.println(.verbose, "    - {d} tokens", .{tree.tokens.len});

        var results = std.ArrayList(zlinter.results.LintResult).empty;
        errdefer results.deinit(session_arena);

        for (tree.errors) |err| {
            const position = tree.tokenLocation(
                0,
                err.token,
            );

            const problem = zlinter.results.LintProblem{
                .rule_id = "syntax_error",
                .severity = .@"error",
                .start = .{
                    .byte_offset = position.line_start + position.column,
                },
                .end = .{
                    .byte_offset = position.line_start + position.column + tree.tokenSlice(err.token).len - 1,
                },
                .message = try allocAstErrorMsg(tree, err, session_arena),
            };

            const problems = oom(session_arena.alloc(zlinter.results.LintProblem, 1));
            problems[0] = problem;

            const result = oom(zlinter.results.LintResult.init(
                session_arena,
                file_abs_path,
                problems,
            ));

            oom(results.append(session_arena, result));
        }
        printer.println(.verbose, "  - Process syntax errors: {d}ms", .{timer.lapMilliseconds()});

        const compile_context_ids = try context.compileContextIdsForFile(
            file_id,
            file_arena,
        );

        printer.println(.verbose, "  - Rules", .{});

        var rule_it = enabled_rules.iterator(.{ .direction = .forward, .kind = .set });
        while (rule_it.next()) |rule_index| {
            const rule = rules[rule_index];
            switch (rule.execution) {
                .syntax_only => {
                    context.setCompileRootFileId(null);
                    if (try rule.run(
                        rule,
                        &context,
                        &doc,
                        session_arena,
                        .{ .config = rule_configs[rule_index] },
                    )) |result| {
                        try appendDedupedResult(
                            session_arena,
                            &results,
                            &doc,
                            result,
                        );
                    }
                },
                .compile_context => {
                    if (compile_context_ids.len == 0) {
                        context.setCompileRootFileId(null);
                        context.resolveFileTypes(file_id);
                        if (try rule.run(
                            rule,
                            &context,
                            &doc,
                            session_arena,
                            .{ .config = rule_configs[rule_index] },
                        )) |result| {
                            try appendDedupedResult(
                                session_arena,
                                &results,
                                &doc,
                                result,
                            );
                        }
                    } else {
                        for (compile_context_ids) |compile_context_id| {
                            if (!context.focused_compiled_contexts.contains(compile_context_id))
                                continue;

                            const compile_root_file_id = context.compileRootFileId(compile_context_id);
                            context.setCompileRootFileId(compile_root_file_id);
                            context.resolveFileTypes(file_id);
                            if (try rule.run(
                                rule,
                                &context,
                                &doc,
                                session_arena,
                                .{
                                    .config = rule_configs[rule_index],
                                    .compile_context_id = compile_context_id,
                                    .compile_root_file_id = compile_root_file_id,
                                },
                            )) |result| {
                                try appendDedupedResult(
                                    session_arena,
                                    &results,
                                    &doc,
                                    result,
                                );
                            }
                        }
                    }
                },
            }

            const ns = timer.lapNanoseconds();
            if (maybe_rule_elapsed_times) |*rule_elapsed_time| {
                rule_elapsed_time[rule_index] += ns;
            }
            printer.println(.verbose, "    - {s}: {d}ms", .{ rule.rule_id, ns / std.time.ns_per_ms });
        }

        if (results.items.len > 0) {
            oom(file_lint_problems.putNoClobber(
                session_arena,
                std.math.cast(u32, i) orelse @panic("Too many files"),
                oom(results.toOwnedSlice(session_arena)),
            ));
        }
    }
}

fn sameProblem(
    lhs: zlinter.results.LintProblem,
    rhs: zlinter.results.LintProblem,
) bool {
    return std.mem.eql(u8, lhs.rule_id, rhs.rule_id) and
        lhs.severity == rhs.severity and
        lhs.start.byte_offset == rhs.start.byte_offset and
        lhs.end.byte_offset == rhs.end.byte_offset and
        std.mem.eql(u8, lhs.message, rhs.message);
}

fn containsProblem(
    results: []const zlinter.results.LintResult,
    problem: zlinter.results.LintProblem,
) bool {
    for (results) |result| {
        for (result.problems) |existing_problem| {
            if (sameProblem(existing_problem, problem)) return true;
        }
    }
    return false;
}

fn containsProblemInSlice(
    problems: []const zlinter.results.LintProblem,
    problem: zlinter.results.LintProblem,
) bool {
    for (problems) |existing_problem| {
        if (sameProblem(existing_problem, problem)) return true;
    }
    return false;
}

fn appendDedupedResult(
    session_arena: std.mem.Allocator,
    results: *std.ArrayList(zlinter.results.LintResult),
    doc: *zlinter.session.LintDocument,
    result: zlinter.results.LintResult,
) error{OutOfMemory}!void {
    var deduped_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    errdefer deduped_problems.deinit(session_arena);

    for (result.problems) |problem| {
        var deduped_problem = problem;
        deduped_problem.disabled_by_comment = try doc.shouldSkipProblem(deduped_problem);

        if (containsProblem(results.items, deduped_problem)) continue;
        if (containsProblemInSlice(deduped_problems.items, deduped_problem)) continue;

        try deduped_problems.append(session_arena, deduped_problem);
    }

    if (deduped_problems.items.len == 0) return;

    try results.append(session_arena, .{
        .abs_path = result.abs_path,
        .problems = try deduped_problems.toOwnedSlice(session_arena),
    });
}

fn runFormatter(
    io: std.Io,
    session_arena: std.mem.Allocator,
    cwd: []const u8,
    file_lint_problems: std.array_hash_map.Auto(u32, []zlinter.results.LintResult),
    output_writer: *std.Io.Writer,
    output_tty: zlinter.ansi.Tty,
    formatter: *const zlinter.formatters.Formatter,
    quiet: bool,
    max_warnings: ?u32,
) !RunResult {
    var run_result: RunResult = .success;
    var warning_count: usize = 0;
    var results_count: usize = 0;
    for (file_lint_problems.values()) |results| {
        results_count += results.len;
        for (results) |result| {
            for (result.problems) |problem| {
                if (problem.disabled_by_comment) continue;
                switch (problem.severity) {
                    .@"error" => run_result = .lint_error,
                    .warning => warning_count += 1,
                    .off => {},
                }
            }
        }
    }
    if (max_warnings) |max| {
        if (warning_count > max) {
            run_result = .lint_error;
        }
    }

    var flattened = try std.ArrayList(zlinter.results.LintResult).initCapacity(
        session_arena,
        results_count,
    );
    for (file_lint_problems.values()) |results| {
        flattened.appendSliceAssumeCapacity(results);
    }

    try formatter.format(.{
        .results = try flattened.toOwnedSlice(session_arena),
        .cwd = cwd,
        .arena = session_arena,
        .tty = output_tty,
        .min_severity = if (quiet) .@"error" else .warning,
        .io = io,
    }, output_writer);

    return run_result;
}

fn allocCwdRelPath(gpa: std.mem.Allocator, cwd: []const u8, abs_path: []const u8) ![]const u8 {
    return std.fs.path.relative(gpa, cwd, null, cwd, abs_path);
}

fn cmpFix(context: void, a: zlinter.results.LintProblemFix, b: zlinter.results.LintProblemFix) bool {
    return std.sort.asc(@TypeOf(a.start))(context, a.start, b.start);
}

fn runFixes(
    io: std.Io,
    session_arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    cwd: []const u8,
    lint_files: []zlinter.files.LintFile,
    file_lint_problems: std.array_hash_map.Auto(u32, []zlinter.results.LintResult),
    printer: *zlinter.rendering.Printer,
) !RunResult {
    var total_fixes: usize = 0;
    var total_disabled_by_comment: usize = 0;

    var file_arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer file_arena_allocator.deinit();
    const file_arena = file_arena_allocator.allocator();

    var it = file_lint_problems.iterator();
    while (it.next()) |entry| {
        defer _ = file_arena_allocator.reset(.retain_capacity);

        var lint_fixes = std.ArrayList(zlinter.results.LintProblemFix).empty;

        const results = entry.value_ptr.*;
        for (results) |result| {
            for (result.problems) |err| {
                if (err.disabled_by_comment) {
                    total_disabled_by_comment += 1;
                    continue;
                }

                if (err.fix) |fix| {
                    try lint_fixes.append(session_arena, fix);
                }
            }
        }

        // Sort by range start and then remove overlaps to avoid conflicting
        // changes. This is needed as we do text based fixes.
        std.mem.sort(
            zlinter.results.LintProblemFix,
            lint_fixes.items,
            {},
            cmpFix,
        );

        const abs_path = lint_files[entry.key_ptr.*].abs_path;

        var file_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var fba: std.heap.FixedBufferAllocator = .init(&file_path_buffer);
        const cwd_rel_path = try allocCwdRelPath(fba.allocator(), cwd, abs_path);

        const file = try std.Io.Dir.openFileAbsolute(io, abs_path, .{
            .mode = .read_only,
        });
        defer file.close(io);

        const file_content = file_content: {
            var file_reader_buffer: [1024]u8 = undefined;
            var file_reader = file.readerStreaming(io, &file_reader_buffer);

            var buffer: std.Io.Writer.Allocating = .init(file_arena);
            defer buffer.deinit();

            if (file_reader.getSize()) |size| {
                const casted_size = std.math.cast(u32, size) orelse return error.StreamTooLong;
                oom(buffer.ensureTotalCapacity(casted_size));
            } else |_| {
                // Do nothing.
            }

            _ = try file_reader.interface.streamRemaining(&buffer.writer);
            break :file_content oom(buffer.toOwnedSlice());
        };

        var output_slices = std.ArrayList([]const u8).empty;

        var file_fixes: usize = 0;
        var content_index: usize = 0;
        var previous_fix: ?zlinter.results.LintProblemFix = null;
        for (lint_fixes.items) |fix| {
            if (previous_fix) |p| {
                if (fix.start <= p.end) {
                    // Skip this fix as it collides with previous fixes range
                    // and may cause an invalid result.
                    continue;
                }
            }
            previous_fix = fix;

            oom(output_slices.append(file_arena, file_content[content_index..fix.start]));
            if (fix.text.len > 0) {
                oom(output_slices.append(file_arena, fix.text));
            }
            content_index = fix.end;
            total_fixes += 1;
            file_fixes += 1;
        }
        if (content_index < file_content.len - 1) {
            oom(output_slices.append(file_arena, file_content[content_index..file_content.len]));
        }

        printer.print(.out, "{s}{d} fixes{s} applied to: {s}\n", .{
            printer.tty.ansiOrEmpty(&.{.bold}),
            file_fixes,
            printer.tty.ansiOrEmpty(&.{.reset}),
            cwd_rel_path,
        });

        if (output_slices.items.len > 0) {
            const new_file = try std.Io.Dir.createFileAbsolute(io, abs_path, .{
                .truncate = true,
            });
            defer new_file.close(io);

            var buffer: [1024]u8 = undefined;
            var writer = new_file.writer(io, &buffer);
            for (output_slices.items) |output_slice| {
                try writer.interface.writeAll(output_slice);
            }
            try writer.interface.flush();
        }
    }

    printer.print(
        .out,
        "{s}Fixed {d} issues{s} in {s}{d} files!{s}\n{d} issues disabled by comments.\n",
        .{
            printer.tty.ansiOrEmpty(&.{.bold}),
            total_fixes,
            printer.tty.ansiOrEmpty(&.{.reset}),
            printer.tty.ansiOrEmpty(&.{.bold}),
            file_lint_problems.count(),
            printer.tty.ansiOrEmpty(&.{.reset}),
            total_disabled_by_comment,
        },
    );

    return .{ .exit_code = .success, .fixes_applied = total_fixes };
}

/// Allocates an AST error into a string.
///
/// The returned string must be freed by the caller. i.e., `allocator.free(error_message);`
fn allocAstErrorMsg(
    tree: Ast,
    err: Ast.Error,
    allocator: std.mem.Allocator,
) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    try tree.renderError(err, &aw.writer);
    return aw.toOwnedSlice();
}

// TODO: Move buildExcludesIndex and buildFilterIndex to lib and write unit tests

/// Returns an index of files to exclude if exclude configuration is found in args
fn buildExcludesIndex(io: std.Io, cwd: []const u8, gpa: std.mem.Allocator, dir: std.Io.Dir, args: zlinter.Args) !?std.BufSet {
    if (args.exclude_paths == null and args.build_info.exclude_paths == null) return null;

    const exclude_lint_paths: ?[]zlinter.files.LintFile = exclude: {
        if (args.exclude_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(io, cwd, dir, p, gpa);
        } else break :exclude null;
    };
    defer {
        if (exclude_lint_paths) |exclude| {
            for (exclude) |*lint_file| lint_file.deinit(gpa);
            gpa.free(exclude);
        }
    }

    const build_exclude_lint_paths: ?[]zlinter.files.LintFile = exclude: {
        // `--include` argument supersedes build defined includes and excludes
        if (args.include_paths != null) break :exclude null;

        if (args.build_info.exclude_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(io, cwd, dir, p, gpa);
        } else break :exclude null;
    };
    defer {
        if (build_exclude_lint_paths) |files| {
            for (files) |*file| file.deinit(gpa);
            gpa.free(files);
        }
    }

    var index = std.BufSet.init(gpa);
    errdefer index.deinit();

    if (exclude_lint_paths) |files| {
        for (files) |file| try index.insert(file.abs_path);
    }

    if (build_exclude_lint_paths) |files| {
        for (files) |file| try index.insert(file.abs_path);
    }

    return index;
}

/// Returns an index of files to only include if filter configuration is found in args
fn buildFilterIndex(io: std.Io, cwd: []const u8, gpa: std.mem.Allocator, dir: std.Io.Dir, args: zlinter.Args) !?std.BufSet {
    const filter_paths: []zlinter.files.LintFile = exclude: {
        if (args.filter_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(io, cwd, dir, p, gpa);
        } else return null;
    };
    defer {
        for (filter_paths) |*lint_file| lint_file.deinit(gpa);
        gpa.free(filter_paths);
    }

    var index = std.BufSet.init(gpa);
    errdefer index.deinit();

    for (filter_paths) |file| try index.insert(file.abs_path);
    return index;
}

/// Creates and returns a bitset representing enabled rules using the fixed
/// indices in the rules array. This is what allows people to filter runs with
/// the `--rule` CLI argument.
fn enabledRules(filter_rule_ids: ?[]const []const u8) std.StaticBitSet(rules.len) {
    var bitset: std.StaticBitSet(rules.len) = .full;
    if (filter_rule_ids == null) return bitset;

    bitset.toggleAll();
    for (rules, 0..) |rule, i| {
        filters: for (filter_rule_ids.?) |filter_id| {
            if (std.mem.eql(u8, rule.rule_id, filter_id)) {
                bitset.set(i);
                break :filters;
            }
        }
    }
    return bitset;
}

const ExitCode = enum(u8) {
    /// No lint errors - everything ran smoothly
    success = 0,

    /// The tool itself blew up (i.e., a bug to be reported)
    tool_error = 1,

    /// A lint problem with severity error is found (i.e., fixable by user)
    lint_error = 2,

    /// An error in the usage of zlinter occured. e.g., an incorrect flag (i.e., fixable by user)
    usage_error = 3,

    pub inline fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

const RunResult = struct {
    exit_code: ExitCode,
    fixes_applied: usize = 0,

    const success: RunResult = .{ .exit_code = .success };
    const tool_error: RunResult = .{ .exit_code = .tool_error };
    const lint_error: RunResult = .{ .exit_code = .lint_error };
    const usage_error: RunResult = .{ .exit_code = .usage_error };
};

const Timer = struct {
    last_timestamp: std.Io.Timestamp,
    io: std.Io,

    pub fn createStarted(io: std.Io) Timer {
        return .{
            .last_timestamp = std.Io.Clock.now(.awake, io),
            .io = io,
        };
    }

    pub fn lapNanoseconds(self: *Timer) usize {
        const current = std.Io.Clock.now(.awake, self.io);
        const elapsed = self.last_timestamp.durationTo(current).toNanoseconds();
        self.last_timestamp = current;
        return @intCast(elapsed);
    }

    pub fn lapMilliseconds(self: *Timer) usize {
        return self.lapNanoseconds() / std.time.ns_per_ms;
    }
};

/// Used to track the slowest rules and files in a priority queue in verbose mode.
const SlowestItemQueue = struct {
    max: usize = 10,
    queue: std.PriorityDequeue(
        Item,
        void,
        Item.compare,
    ),
    gpa: std.mem.Allocator,

    const Item = struct {
        name: []const u8,
        elapsed_ns: usize,

        pub fn compare(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(a.elapsed_ns, b.elapsed_ns);
        }
    };

    fn init(gpa: std.mem.Allocator) SlowestItemQueue {
        return .{
            .queue = .empty,
            .gpa = gpa,
        };
    }

    fn deinit(self: *SlowestItemQueue) void {
        for (self.queue.items) |item| {
            self.gpa.free(item.name);
        }
        self.queue.deinit(self.gpa);
        self.* = undefined;
    }

    fn add(self: *SlowestItemQueue, item: Item) void {
        const owned_name = self.gpa.dupe(u8, item.name) catch return;
        const owned_item: Item = .{
            .name = owned_name,
            .elapsed_ns = item.elapsed_ns,
        };

        if (self.queue.push(self.gpa, owned_item)) {
            if (self.queue.count() > self.max) {
                if (self.queue.popMin()) |removed| {
                    self.gpa.free(removed.name);
                }
            }
        } else |_| self.gpa.free(owned_name);
    }

    fn unloadAndPrint(self: *SlowestItemQueue, name: []const u8, printer: *zlinter.rendering.Printer) void {
        if (self.queue.count() == 0) return;

        printer.printBanner(.verbose);
        printer.println(.verbose, "Slowest {d} {s}:", .{
            self.queue.items.len,
            name,
        });
        printer.printBanner(.verbose);

        var i: usize = 0;
        while (self.queue.popMax()) |item| {
            defer self.gpa.free(item.name);

            printer.println(.verbose, "  {d:02} -  {s}[{d}ms]{s} {s}", .{
                i,
                printer.tty.ansiOrEmpty(&.{.bold}),
                item.elapsed_ns / std.time.ns_per_ms,
                printer.tty.ansiOrEmpty(&.{.reset}),
                item.name,
            });
            i += 1;
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const rules = @import("rules").rules; // Generated in build_rules.zig
const rules_configs = @import("rules").rules_configs; // Generated in build_rules.zig
const rules_configs_types = @import("rules").rules_configs_types; // Generated in build_rules.zig
const Ast = std.zig.Ast;
const oom = zlinter.allocations.oom;
