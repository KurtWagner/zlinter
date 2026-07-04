const default_formatter = zlinter.formatters.DefaultFormatter{};

pub const std_options: std.Options = .{
    .log_level = if (@import("zlinter_build_config").verbose)
        .info
    else
        .err,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.smp_allocator;

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
            gpa,
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
    defer args.deinit(gpa);

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

    var runtime: LintRuntime = .init(io, gpa, args);
    defer runtime.deinit(gpa);

    var total_fixes: usize = 0;
    const result = result: {
        var remaining_fix_passes = @max(1, args.fix_passes);
        while (remaining_fix_passes > 0) {
            if (run(
                &runtime,
                gpa,
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
    runtime: *const LintRuntime,
    gpa: std.mem.Allocator,
    args: zlinter.Args,
    printer: *zlinter.rendering.Printer,
) !RunResult {
    const io = runtime.io;

    var timer = Timer.createStarted(io);
    var total_timer = Timer.createStarted(io);

    var file_lint_problems = std.array_hash_map.Auto(
        zlinter.session.FileStore.FileId,
        []zlinter.results.LintResult,
    ).empty;

    // ------------------------------------------------------------------------
    // Resolve files then apply excludes and filters
    // ------------------------------------------------------------------------

    var dir = try std.Io.Dir.cwd().openDir(io, "./", .{ .iterate = true });
    defer dir.close(io);

    const lint_files = try zlinter.files.allocLintFiles(
        runtime,
        dir,
        // `--include` argument supersedes build defined includes and excludes
        args.include_paths orelse args.build_info.include_paths orelse null,
        gpa,
    );

    if (try buildExcludesIndex(
        runtime,
        gpa,
        dir,
        args,
    )) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = index.contains(file.abs_path);
    }

    if (try buildFilterIndex(
        runtime,
        dir,
        args,
    )) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = !index.contains(file.abs_path);
    }

    printer.println(.verbose, "Resolving {d} files took: {d}ms", .{ lint_files.len, timer.lapMilliseconds() });

    var session: zlinter.session.LintSession = .{
        .runtime = runtime,
        .file_store = .init(runtime),
        .module_store = .init(runtime),
        .build_config_store = .init(runtime),
        .type_store = .init(runtime),
        .decl_store = .init(runtime),
    };
    try session.init(args.build_info);

    // Resolve the files to be linted once at the start and pass around file
    // ids to linting, fixing and rendering phases instead of absolute path.
    var lint_file_ids = std.ArrayList(zlinter.session.FileStore.FileId).initCapacity(
        runtime.sessionArena(),
        lint_files.len,
    ) catch @panic("OOM");
    for (lint_files) |file| {
        if (file.excluded) continue;

        if (session.file_store.resolve(file.abs_path)) |file_id|
            lint_file_ids.appendAssumeCapacity(file_id)
        else |e|
            printer.println(.err, "Unable to open file: {s} ({s})", .{ runtime.cwd, @errorName(e) });
    }

    try runLinterRules(
        &session,
        lint_file_ids.items,
        printer,
        &timer,
        &file_lint_problems,
        args,
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
            &session,
            file_lint_problems,
            printer,
        )
    else
        try runFormatter(
            &session,
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

/// Resolves lint files, prepares one session, and runs each enabled rule once
/// per file.
fn runLinterRules(
    session: *zlinter.session.LintSession,
    lint_file_ids: []zlinter.session.FileStore.FileId,
    printer: *zlinter.rendering.Printer,
    timer: *Timer,
    file_lint_problems: *std.array_hash_map.Auto(
        zlinter.session.FileStore.FileId,
        []zlinter.results.LintResult,
    ),
    args: zlinter.Args,
) !void {
    const runtime = session.runtime;

    var maybe_slowest_files = if (runtime.verbose) SlowestItemQueue.init(runtime.sessionArena()) else null;
    defer if (maybe_slowest_files) |*slowest_files| {
        defer slowest_files.deinit();
        slowest_files.unloadAndPrint("Files", printer);
    };

    var maybe_rule_elapsed_times: ?[rules.len]usize = if (runtime.verbose)
        @splat(0)
    else
        null;
    defer if (maybe_rule_elapsed_times) |*rule_elapsed_times| {
        var item_timers = SlowestItemQueue.init(runtime.sessionArena());
        defer item_timers.deinit();

        for (rule_elapsed_times, 0..) |elapsed_ns, rule_id| {
            item_timers.add(.{
                .name = rules[rule_id].rule_id,
                .elapsed_ns = elapsed_ns,
            });
        }
        item_timers.unloadAndPrint("Rules", printer);
    };

    var enabled_rules = enabledRules(args.rules);

    var lint_config_store: LintConfigStore = .init(
        runtime.sessionArena(),
        rule_configs,
    );

    files: for (lint_file_ids, 0..) |file_id, i| {
        defer runtime.resetFileArena();

        const file_abs_path = session.file_store.fileAbsPath(file_id);
        printer.println(.verbose, "[{d}/{d}] Linting: {s}", .{ i + 1, lint_file_ids.len, file_abs_path });

        try lint_config_store.index(
            runtime.io,
            runtime.sessionArena(),
            std.fs.path.dirname(file_abs_path).?,
            std.Io.Dir.cwd(),
        );

        var rule_timer = Timer.createStarted(runtime.io);
        defer {
            const ns = rule_timer.lapNanoseconds();
            printer.println(.verbose, "  - Total elapsed {d}ms", .{ns / std.time.ns_per_ms});
            if (maybe_slowest_files) |*slowest_files| {
                slowest_files.add(.{
                    .name = file_abs_path,
                    .elapsed_ns = ns,
                });
            }
        }

        var doc: zlinter.session.LintDocument = undefined;
        session.initDocument(file_id, runtime.fileArena(), &doc) catch |e| {
            printer.println(.err, "Unable to open file: {s} ({s})", .{ file_abs_path, @errorName(e) });
            continue :files;
        };

        printer.println(.verbose, "  - Load document: {d}ms", .{timer.lapMilliseconds()});
        const tree = doc.tree(session);
        printer.println(.verbose, "    - {d} bytes", .{tree.source.len});
        printer.println(.verbose, "    - {d} nodes", .{tree.nodes.len});
        printer.println(.verbose, "    - {d} tokens", .{tree.tokens.len});

        var results = std.ArrayList(zlinter.results.LintResult).empty;
        errdefer results.deinit(runtime.sessionArena());

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
                .message = try allocAstErrorMsg(tree, err, runtime.sessionArena()),
            };

            const problems = oom(runtime.sessionArena().alloc(zlinter.results.LintProblem, 1));
            problems[0] = problem;

            const result = oom(zlinter.results.LintResult.init(
                file_id,
                problems,
            ));

            oom(results.append(runtime.sessionArena(), result));
        }
        printer.println(.verbose, "  - Process syntax errors: {d}ms", .{timer.lapMilliseconds()});

        session.resolveFileTypes(file_id);

        printer.println(.verbose, "  - Rules", .{});

        var rule_it = enabled_rules.iterator(.{ .direction = .forward, .kind = .set });
        while (rule_it.next()) |rule_index| {
            defer runtime.resetRuleArena();

            const rule_id: RuleId = @intCast(rule_index);

            const rule = rules[rule_id];
            const rule_zone = tracy.traceNamed(@src(), "run_linter.rule");
            defer rule_zone.end();
            rule_zone.addText(rule.rule_id);
            rule_zone.addText(file_abs_path);
            if (try rule.run(
                rule,
                session,
                &doc,
                .{
                    .config = lint_config_store.lookup(
                        std.fs.path.dirname(file_abs_path).?,
                        rule_id,
                    ),
                },
            )) |result| {
                try appendDedupedResult(
                    runtime.sessionArena(),
                    &results,
                    &doc,
                    result,
                );
            }

            const ns = timer.lapNanoseconds();
            if (maybe_rule_elapsed_times) |*rule_elapsed_time| {
                rule_elapsed_time[rule_index] += ns;
            }
            printer.println(.verbose, "    - {s}: {d}ms", .{ rule.rule_id, ns / std.time.ns_per_ms });
        }

        if (results.items.len > 0) {
            oom(file_lint_problems.putNoClobber(
                runtime.sessionArena(),
                file_id,
                oom(results.toOwnedSlice(runtime.sessionArena())),
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
        std.mem.eql(u8, lhs.message, rhs.message) and
        sameProblemNotes(lhs.notes, rhs.notes);
}

fn sameProblemNotes(
    lhs: ?[]zlinter.results.LintProblemNote,
    rhs: ?[]zlinter.results.LintProblemNote,
) bool {
    if (lhs == null and rhs == null) return true;
    const lhs_notes = lhs orelse return false;
    const rhs_notes = rhs orelse return false;
    if (lhs_notes.len != rhs_notes.len) return false;

    for (lhs_notes, rhs_notes) |lhs_note, rhs_note| {
        if (lhs_note.file_id != rhs_note.file_id) return false;
        if (lhs_note.start.byte_offset != rhs_note.start.byte_offset) return false;
        if (lhs_note.end.byte_offset != rhs_note.end.byte_offset) return false;
        if (lhs_note.line != rhs_note.line) return false;
        if (lhs_note.column != rhs_note.column) return false;
        if (!std.mem.eql(u8, lhs_note.message, rhs_note.message)) return false;
    }

    return true;
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
        .file_id = result.file_id,
        .problems = try deduped_problems.toOwnedSlice(session_arena),
    });
}

fn runFormatter(
    session: *zlinter.session.LintSession,
    file_lint_problems: std.array_hash_map.Auto(
        zlinter.session.FileStore.FileId,
        []zlinter.results.LintResult,
    ),
    output_writer: *std.Io.Writer,
    output_tty: zlinter.ansi.Tty,
    formatter: *const zlinter.formatters.Formatter,
    quiet: bool,
    max_warnings: ?u32,
) !RunResult {
    const runtime = session.runtime;
    const session_arena = runtime.sessionArena();

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
        .file_store = &session.file_store,
        .cwd = runtime.cwd,
        .zig_lib_directory = runtime.zig_lib_directory,
        .arena = session_arena,
        .tty = output_tty,
        .min_severity = if (quiet) .@"error" else .warning,
        .io = runtime.io,
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
    session: *zlinter.session.LintSession,
    file_lint_problems: std.array_hash_map.Auto(
        zlinter.session.FileStore.FileId,
        []zlinter.results.LintResult,
    ),
    printer: *zlinter.rendering.Printer,
) !RunResult {
    const runtime = session.runtime;

    var total_fixes: usize = 0;
    var total_disabled_by_comment: usize = 0;

    var it = file_lint_problems.iterator();
    while (it.next()) |entry| {
        defer runtime.resetFileArena();

        var lint_fixes = std.ArrayList(zlinter.results.LintProblemFix).empty;

        const results = entry.value_ptr.*;
        for (results) |result| {
            for (result.problems) |err| {
                if (err.disabled_by_comment) {
                    total_disabled_by_comment += 1;
                    continue;
                }

                if (err.fix) |fix| {
                    try lint_fixes.append(runtime.sessionArena(), fix);
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

        const file_id = entry.key_ptr.*;
        const abs_path = session.file_store.fileAbsPath(file_id);

        const cwd_rel_path = oom(allocCwdRelPath(
            runtime.sessionArena(),
            runtime.cwd,
            abs_path,
        ));

        const file_content = session.file_store.fileSource(file_id);

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

            oom(output_slices.append(runtime.fileArena(), file_content[content_index..fix.start]));
            if (fix.text.len > 0) {
                oom(output_slices.append(runtime.fileArena(), fix.text));
            }
            content_index = fix.end;
            total_fixes += 1;
            file_fixes += 1;
        }
        if (content_index < file_content.len - 1) {
            oom(output_slices.append(runtime.fileArena(), file_content[content_index..file_content.len]));
        }

        printer.print(.out, "{s}{d} fixes{s} applied to: {s}\n", .{
            printer.tty.ansiOrEmpty(&.{.bold}),
            file_fixes,
            printer.tty.ansiOrEmpty(&.{.reset}),
            cwd_rel_path,
        });

        if (output_slices.items.len > 0) {
            const new_file = try std.Io.Dir.createFileAbsolute(runtime.io, abs_path, .{
                .truncate = true,
            });
            defer new_file.close(runtime.io);

            var buffer: [1024]u8 = undefined;
            var writer = new_file.writer(runtime.io, &buffer);
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
fn buildExcludesIndex(
    runtime: *const LintRuntime,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    args: zlinter.Args,
) !?std.BufSet {
    if (args.exclude_paths == null and args.build_info.exclude_paths == null) return null;

    const exclude_lint_paths: ?[]zlinter.files.LintFile = exclude: {
        if (args.exclude_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(runtime, dir, p, gpa);
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
            break :exclude try zlinter.files.allocLintFiles(runtime, dir, p, gpa);
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
fn buildFilterIndex(runtime: *const LintRuntime, dir: std.Io.Dir, args: zlinter.Args) !?std.BufSet {
    const session_arena = runtime.sessionArena();

    const filter_paths: []zlinter.files.LintFile = exclude: {
        if (args.filter_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(runtime, dir, p, session_arena);
        } else return null;
    };
    defer {
        for (filter_paths) |*lint_file| lint_file.deinit(session_arena);
        session_arena.free(filter_paths);
    }

    var index = std.BufSet.init(session_arena);
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

const LintConfigStore = struct {
    pub const LintConfigId = u32;

    base_config_id: LintConfigId,
    configs: std.ArrayList(LintConfig),
    config_by_dir_abs_path: std.StringHashMapUnmanaged(?LintConfigId),

    pub fn init(arena: std.mem.Allocator, base_rule_configs: [rules.len]*anyopaque) LintConfigStore {
        var self: LintConfigStore = .{
            .configs = .empty,
            .config_by_dir_abs_path = .empty,
            .base_config_id = 0,
        };

        oom(self.configs.append(arena, .{
            .rule_configs = base_rule_configs,
            .rule_configs_on = .full,
        }));

        return self;
    }

    pub fn index(
        self: *LintConfigStore,
        io: std.Io,
        arena: std.mem.Allocator,
        dir_abs_path: []const u8,
        cwd: std.Io.Dir,
    ) error{InvalidLintConfig}!void {
        std.debug.assert(std.fs.path.isAbsolute(dir_abs_path));

        const normalized_slice = std.mem.trimEnd(
            u8,
            dir_abs_path,
            std.fs.path.sep_str,
        );
        if (normalized_slice.len == 0) return;

        // We only make a copy for key indexing if we need to index part of the
        // path, in which case we make a copy of it and base all slices keys
        // off it in memory stored in the arena.
        var maybe_normalized_copy: ?[]const u8 = null;

        for (normalized_slice, 0..) |c, i| {
            if (!std.fs.path.isSep(c)) continue;

            if (self.needsIndexing(normalized_slice[0..i])) {
                if (maybe_normalized_copy == null)
                    maybe_normalized_copy = oom(arena.dupe(u8, normalized_slice));
                try self.insertIntoIndex(
                    io,
                    arena,
                    maybe_normalized_copy.?[0..i],
                    cwd,
                );
            }
        }
        if (self.needsIndexing(normalized_slice[0..])) {
            if (maybe_normalized_copy == null)
                maybe_normalized_copy = oom(arena.dupe(u8, normalized_slice));
            try self.insertIntoIndex(
                io,
                arena,
                maybe_normalized_copy.?[0..],
                cwd,
            );
        }
    }

    /// Returns true if `insertIntoIndex` needs to be called for a path.
    fn needsIndexing(
        self: *const LintConfigStore,
        dir_abs_sub_path: []const u8,
    ) bool {
        return dir_abs_sub_path.len > 0 and
            !self.config_by_dir_abs_path.contains(dir_abs_sub_path);
    }

    /// Inserts a path into the index, should check `needsIndexing` before
    /// calling this.
    fn insertIntoIndex(
        self: *LintConfigStore,
        io: std.Io,
        arena: std.mem.Allocator,
        dir_abs_sub_path: []const u8,
        cwd: std.Io.Dir,
    ) error{InvalidLintConfig}!void {
        std.debug.assert(self.needsIndexing(dir_abs_sub_path));

        std.log.info("Index zlinter config: '{s}'", .{dir_abs_sub_path});
        if (try LintConfig.tryLoad(
            io,
            arena,
            cwd,
            dir_abs_sub_path,
        )) |config| {
            const config_id: LintConfigId = @intCast(self.configs.items.len);
            oom(self.configs.append(arena, config));
            oom(self
                .config_by_dir_abs_path
                .putNoClobber(
                arena,
                dir_abs_sub_path,
                config_id,
            ));
        } else {
            oom(self
                .config_by_dir_abs_path
                .putNoClobber(
                arena,
                dir_abs_sub_path,
                null,
            ));
        }
    }

    pub fn lookup(self: *const LintConfigStore, dir_abs_path: []const u8, rule_id: RuleId) *anyopaque {
        const zone = tracy.traceNamed(@src(), "LintConfigStore.lookup");
        defer zone.end();

        std.debug.assert(std.fs.path.isAbsolute(dir_abs_path));
        std.debug.assert(dir_abs_path.len > 0);

        const normalized = std.mem.trimEnd(
            u8,
            dir_abs_path,
            std.fs.path.sep_str,
        );
        std.debug.assert(normalized.len > 0);

        if (self.configByDir(normalized)) |config| {
            const lint_config = self.configs.items[config];
            if (lint_config.rule_configs_on.isSet(rule_id))
                return lint_config.rule_configs[rule_id];
        }

        var rhs = normalized.len;
        while (rhs > 0) : (rhs -= 1) {
            if (std.fs.path.isSep(normalized[rhs - 1])) {
                const parent_dir = normalized[0 .. rhs - 1];
                if (self.configByDir(parent_dir)) |config| {
                    const lint_config = self.configs.items[config];
                    if (lint_config.rule_configs_on.isSet(rule_id))
                        return lint_config.rule_configs[rule_id];
                }
            }
        }
        std.log.info("No zlinter.zon for {s}", .{dir_abs_path});
        return self.configs.items[self.base_config_id].rule_configs[rule_id];
    }

    pub fn getConfig(self: *const LintConfigStore, config_id: LintConfigId, rule_id: RuleId) *anyopaque {
        return self.configs.items[config_id].rule_configs[rule_id];
    }

    fn configByDir(self: *const LintConfigStore, dir_abs_path: []const u8) ?LintConfigId {
        return self.config_by_dir_abs_path.get(dir_abs_path) orelse null;
    }

    const LintConfig = struct {
        const max_config_size_bytes = 10 * 1025;

        rule_configs: [rules.len]*anyopaque,
        rule_configs_on: std.bit_set.Static(rules.len),

        /// What users write in nested directories to overwrite specific rule configs.
        const Zon = struct {
            rules: RulesConfig,
        };

        pub const empty: LintConfig = .{
            .rule_configs = undefined,
            .rule_configs_on = .empty,
        };

        pub fn tryLoad(
            io: std.Io,
            arena: std.mem.Allocator,
            cwd: std.Io.Dir,
            dir_abs_path: []const u8,
        ) error{InvalidLintConfig}!?LintConfig {
            var fba_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            var fba_path: std.heap.FixedBufferAllocator = .init(&fba_path_buffer);

            const lint_config_abs_path = std.fs.path.resolve(
                fba_path.allocator(),
                &.{ dir_abs_path, "zlinter.zon" },
            ) catch unreachable;

            std.log.info("Looking for: '{s}'", .{lint_config_abs_path});

            var fba_config_buffer: [max_config_size_bytes]u8 = undefined;
            var fba_config: std.heap.FixedBufferAllocator = .init(&fba_config_buffer);

            const source = cwd.readFileAllocOptions(
                io,
                lint_config_abs_path,
                fba_config.allocator(),
                .limited(max_config_size_bytes),
                .of(u8),
                0,
            ) catch |e| switch (e) {
                error.FileNotFound => {
                    return null;
                },
                else => {
                    std.log.err(
                        "Could not read lint config '{s}' due to: {t}",
                        .{ lint_config_abs_path, e },
                    );
                    return error.InvalidLintConfig;
                },
            };

            @setEvalBranchQuota(5000);
            var diagnostics: std.zon.parse.Diagnostics = .{};
            const zon = oom(arena.create(Zon));
            zon.* = std.zon.parse.fromSliceAlloc(
                Zon,
                arena,
                source,
                &diagnostics,
                .{},
            ) catch |e| {
                if (e == error.OutOfMemory) @panic("OOM");
                std.log.err(
                    "Failed to parse lint config: '{s}' due to {t} - {f}",
                    .{ lint_config_abs_path, e, diagnostics },
                );
                return error.InvalidLintConfig;
            };

            var self: LintConfig = .empty;
            inline for (0..rules.len) |i| {
                if (@field(zon.rules, rule_names[i])) |*v| {
                    self.rule_configs[i] = @ptrCast(@alignCast(v));
                    self.rule_configs_on.set(i);
                }
            }

            return self;
        }
    };
};

test "LintConfigStore.index errors on malformed zlinter.zon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(std.testing.io, "nested");
    try zlinter.testing.writeFile(
        tmp_dir.dir,
        "nested/zlinter.zon",
        ".{ .rules = .{ .no_unused = ",
    );

    var dir_abs_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs_path = dir_abs_path_buffer[0..try tmp_dir.dir.realPath(
        std.testing.io,
        "nested",
        &dir_abs_path_buffer,
    )];

    var store = LintConfigStore.init(
        arena.allocator(),
        rule_configs,
    );
    try std.testing.expectError(
        error.InvalidLintConfig,
        store.index(
            std.testing.io,
            arena.allocator(),
            dir_abs_path,
            std.Io.Dir.cwd(),
        ),
    );
}

test "LintConfigStore.index errors when zlinter.zon is not readable as a file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try tmp_dir.dir.createDirPath(
        std.testing.io,
        "nested/zlinter.zon",
    );

    var dir_abs_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir_abs_path = dir_abs_path_buffer[0..try tmp_dir.dir.realPath(
        std.testing.io,
        "nested",
        &dir_abs_path_buffer,
    )];

    var store = LintConfigStore.init(
        arena.allocator(),
        rule_configs,
    );
    try std.testing.expectError(
        error.InvalidLintConfig,
        store.index(
            std.testing.io,
            arena.allocator(),
            dir_abs_path,
            std.Io.Dir.cwd(),
        ),
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const rule_names = @import("rules").rule_names; // Generated in build_rules.zig
const RulesConfig = @import("rules").RulesConfig; // Generated in build_rules.zig
const rules = @import("rules").rules; // Generated in build_rules.zig
const rule_configs = @import("rules").rule_configs; // Generated in build_rules.zig
const rule_configs_types = @import("rules").rule_configs_types; // Generated in build_rules.zig
const RuleId = @import("rules").RuleId; // Generated in build_rules.zig
const Ast = std.zig.Ast;
const oom = zlinter.allocations.oom;
const LintRuntime = zlinter.session.LintRuntime;
const tracy = zlinter.tracy;
