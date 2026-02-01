var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const default_formatter = zlinter.formatters.DefaultFormatter{};

pub const std_options: std.Options = .{ .log_level = .err };

pub fn main(init: std.process.Init.Minimal) !u8 {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    // TODO: Work out whether this should swap to the "juicy" main allocators
    const gpa, const is_debug = switch (builtin.mode) {
        // Debug allocator has become significantly slower (since 0.16) so
        // unless explicitly a debug build (defaults to release fast) don't
        // use it.
        .Debug,
        => .{ debug_allocator.allocator(), true },

        .ReleaseSafe,
        .ReleaseFast,
        .ReleaseSmall,
        => .{ std.heap.smp_allocator, false },
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) @panic("Memory leak");
    };

    var environ_map = try init.environ.createMap(gpa);
    defer environ_map.deinit();

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
        try .init(io, std.Io.File.stdout(), &environ_map),
        false,
    );

    const args = args: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        const raw_args = try init.args.toSlice(arena.allocator());

        break :args zlinter.Args.allocParse(
            raw_args,
            &rules,
            gpa,
            &stdin_reader.interface,
        ) catch |e| switch (e) {
            error.InvalidArgs => {
                zlinter.Args.printHelp(printer);
                return ExitCode.usage_error.int();
            },
            error.OutOfMemory => return e,
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

    var total_fixes: usize = 0;
    const result = result: {
        var remaining_fix_passes = @max(1, args.fix_passes);
        while (remaining_fix_passes > 0) {
            if (run(io, &environ_map, gpa, args, printer)) |r| {
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
    environ_map: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    args: zlinter.Args,
    printer: *zlinter.rendering.Printer,
) !RunResult {
    var timer = Timer.createStarted();
    var total_timer = Timer.createStarted();

    // Key is index to `lint_files` and value are errors for the file.
    var file_lint_problems = std.AutoArrayHashMap(
        u32,
        []zlinter.results.LintResult,
    ).init(gpa);
    defer {
        for (file_lint_problems.values()) |results| {
            for (results) |*result| result.deinit(gpa);
            gpa.free(results);
        }
        file_lint_problems.deinit();
    }

    // ------------------------------------------------------------------------
    // Resolve files then apply excludes and filters
    // ------------------------------------------------------------------------

    var dir = try std.Io.Dir.cwd().openDir(io, "./", .{ .iterate = true });
    defer dir.close(io);

    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);

    const lint_files = try zlinter.files.allocLintFiles(
        io,
        cwd,
        dir,
        // `--include` argument supersedes build defined includes and excludes
        args.include_paths orelse args.build_info.include_paths orelse null,
        gpa,
    );
    defer {
        for (lint_files) |*lint_file| lint_file.deinit(gpa);
        gpa.free(lint_files);
    }

    if (try buildExcludesIndex(io, cwd, gpa, dir, args)) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = index.contains(file.pathname);
    }

    if (try buildFilterIndex(io, cwd, gpa, dir, args)) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = !index.contains(file.pathname);
    }

    if (timer.lapMilliseconds()) |ms| printer.println(.verbose, "Resolving {d} files took: {d}ms", .{ lint_files.len, ms });

    try runLinterRules(
        io,
        environ_map,
        gpa,
        lint_files,
        printer,
        &timer,
        &file_lint_problems,
        args,
    );

    printer.printBanner(.verbose);
    printer.println(.verbose, "Linted {d} files", .{lint_files.len});
    if (total_timer.lapMilliseconds()) |ms| printer.println(.verbose, "Took {d}ms", .{ms});
    printer.printBanner(.verbose);

    // ------------------------------------------------------------------------
    // Print out results:
    // ------------------------------------------------------------------------

    return if (args.fix)
        try runFixes(
            io,
            gpa,
            dir,
            lint_files,
            file_lint_problems,
            printer,
        )
    else
        try runFormatter(
            io,
            gpa,
            dir,
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
    environ_map: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    lint_files: []zlinter.files.LintFile,
    printer: *zlinter.rendering.Printer,
    timer: *Timer,
    file_lint_problems: *std.AutoArrayHashMap(u32, []zlinter.results.LintResult),
    args: zlinter.Args,
) !void {
    var maybe_slowest_files = if (args.verbose) SlowestItemQueue.init(gpa) else null;
    defer if (maybe_slowest_files) |*slowest_files| {
        defer slowest_files.deinit();
        slowest_files.unloadAndPrint("Files", printer);
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var maybe_rule_elapsed_times: ?[rules.len]usize = if (args.verbose)
        @splat(0)
    else
        null;
    defer if (maybe_rule_elapsed_times) |*rule_elapsed_times| {
        var item_timers = SlowestItemQueue.init(gpa);
        defer item_timers.deinit();

        for (rule_elapsed_times, 0..) |elapsed_ns, rule_id| {
            item_timers.add(.{
                .name = rules[rule_id].rule_id,
                .elapsed_ns = elapsed_ns,
            });
        }
        item_timers.unloadAndPrint("Rules", printer);
    };

    var context: zlinter.session.LintContext = undefined;
    try context.init(
        .{
            .zig_exe_path = args.zig_exe,
            .zig_lib_path = args.zig_lib_directory,
            .global_cache_path = args.global_cache_root,
        },
        io,
        environ_map,
        gpa,
        arena.allocator(),
    );
    defer context.deinit();

    var enabled_rules = enabledRules(args.rules);

    var config_overrides_arena = std.heap.ArenaAllocator.init(gpa);
    defer config_overrides_arena.deinit();

    var rule_configs: [rules.len]*anyopaque = undefined;
    {
        var rule_it = enabled_rules.iterator(.{ .direction = .forward, .kind = .set });
        while (rule_it.next()) |rule_index| {
            rule_configs[rule_index] = config: {
                if (args.rule_config_overrides) |rule_config_overrides| {
                    if (rule_config_overrides.get(rules[rule_index].rule_id)) |zon_path| {
                        inline for (0..rules_configs_types.len) |i| {
                            if (i == rule_index) {
                                const config_arena = config_overrides_arena.allocator();
                                const config = try config_arena.create(rules_configs_types[i]);
                                errdefer config_arena.destroy(config);

                                var diagnostics: zlinter.zon.Diagnostics = .{};

                                config.* = zlinter.zon.parseFileAlloc(
                                    rules_configs_types[i],
                                    std.Io.Dir.cwd(),
                                    zon_path,
                                    &diagnostics,
                                    io,
                                    config_arena,
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
        if (lint_file.excluded) {
            printer.println(.verbose, "[{d}/{d}] Excluding: {s}", .{ i + 1, lint_files.len, lint_file.pathname });
            continue :files;
        }
        printer.println(.verbose, "[{d}/{d}] Linting: {s}", .{ i + 1, lint_files.len, lint_file.pathname });

        var rule_timer = Timer.createStarted();
        defer {
            if (rule_timer.lapNanoseconds()) |ns| {
                printer.println(.verbose, "  - Total elapsed {d}ms", .{ns / std.time.ns_per_ms});
                if (maybe_slowest_files) |*slowest_files| {
                    slowest_files.add(.{
                        .name = lint_file.pathname,
                        .elapsed_ns = ns,
                    });
                }
            }
        }

        var doc: zlinter.session.LintDocument = undefined;
        context.initDocument(
            lint_file.pathname,
            context.gpa,
            &doc,
        ) catch |e| {
            printer.println(.err, "Unable to open file: {s} ({s})", .{ lint_file.pathname, @errorName(e) });
            continue :files;
        };
        defer doc.deinit(context.gpa);

        if (timer.lapMilliseconds()) |ms|
            printer.println(.verbose, "  - Load document: {d}ms", .{ms})
        else
            printer.println(.verbose, "  - Load document", .{});
        printer.println(.verbose, "    - {d} bytes", .{doc.handle.tree.source.len});
        printer.println(.verbose, "    - {d} nodes", .{doc.handle.tree.nodes.len});
        printer.println(.verbose, "    - {d} tokens", .{doc.handle.tree.tokens.len});

        var results = std.ArrayList(zlinter.results.LintResult).empty;
        defer results.deinit(gpa);

        const tree = doc.handle.tree;
        for (tree.errors) |err| {
            const position = tree.tokenLocation(
                0,
                err.token,
            );

            try results.append(
                gpa,
                zlinter.results.LintResult{
                    .file_path = try gpa.dupe(u8, lint_file.pathname),
                    .problems = try gpa.dupe(zlinter.results.LintProblem, &[1]zlinter.results.LintProblem{.{
                        .rule_id = "syntax_error",
                        .severity = .@"error",
                        .start = .{
                            .byte_offset = position.line_start + position.column,
                        },
                        .end = .{
                            .byte_offset = position.line_start + position.column + tree.tokenSlice(err.token).len - 1,
                        },
                        .message = try allocAstErrorMsg(tree, err, gpa),
                    }}),
                },
            );
        }
        if (timer.lapMilliseconds()) |ms| printer.println(.verbose, "  - Process syntax errors: {d}ms", .{ms});

        printer.println(.verbose, "  - Rules", .{});

        var rule_it = enabled_rules.iterator(.{ .direction = .forward, .kind = .set });
        while (rule_it.next()) |rule_index| {
            const rule = rules[rule_index];
            if (try rule.run(
                rule,
                &context,
                &doc,
                gpa,
                .{ .config = rule_configs[rule_index] },
            )) |result| {
                for (result.problems) |*err| {
                    err.disabled_by_comment = try doc.shouldSkipProblem(err.*);
                }
                try results.append(gpa, result);
            }

            if (timer.lapNanoseconds()) |ns| {
                if (maybe_rule_elapsed_times) |*rule_elapsed_time| {
                    rule_elapsed_time[rule_index] += ns;
                }
                printer.println(.verbose, "    - {s}: {d}ms", .{ rule.rule_id, ns / std.time.ns_per_ms });
            } else printer.println(.verbose, "    - {s}", .{rule.rule_id});
        }

        if (results.items.len > 0) {
            try file_lint_problems.putNoClobber(
                std.math.cast(u32, i) orelse @panic("Too many files"),
                try results.toOwnedSlice(gpa),
            );
        }
    }
}

fn runFormatter(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    file_lint_problems: std.AutoArrayHashMap(u32, []zlinter.results.LintResult),
    output_writer: *std.Io.Writer,
    output_tty: zlinter.ansi.Tty,
    formatter: *const zlinter.formatters.Formatter,
    quiet: bool,
    max_warnings: ?u32,
) !RunResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

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
        arena_allocator,
        results_count,
    );
    for (file_lint_problems.values()) |results| {
        flattened.appendSliceAssumeCapacity(results);
    }

    try formatter.format(.{
        .results = try flattened.toOwnedSlice(arena_allocator),
        .dir = dir,
        .arena = arena_allocator,
        .tty = output_tty,
        .min_severity = if (quiet) .@"error" else .warning,
        .io = io,
    }, output_writer);

    return run_result;
}

fn cmpFix(context: void, a: zlinter.results.LintProblemFix, b: zlinter.results.LintProblemFix) bool {
    return std.sort.asc(@TypeOf(a.start))(context, a.start, b.start);
}

fn runFixes(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    lint_files: []zlinter.files.LintFile,
    file_lint_problems: std.AutoArrayHashMap(u32, []zlinter.results.LintResult),
    printer: *zlinter.rendering.Printer,
) !RunResult {
    var total_fixes: usize = 0;
    var total_disabled_by_comment: usize = 0;

    var it = file_lint_problems.iterator();
    while (it.next()) |entry| {
        var lint_fixes = std.ArrayList(zlinter.results.LintProblemFix).empty;
        defer lint_fixes.deinit(gpa);

        const results = entry.value_ptr.*;
        for (results) |result| {
            for (result.problems) |err| {
                if (err.disabled_by_comment) {
                    total_disabled_by_comment += 1;
                    continue;
                }

                if (err.fix) |fix| {
                    try lint_fixes.append(gpa, fix);
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

        const file_path = lint_files[entry.key_ptr.*].pathname;
        const file = try dir.openFile(io, file_path, .{
            .mode = .read_only,
        });
        defer file.close(io);

        const file_content = file_content: {
            var file_reader_buffer: [1024]u8 = undefined;
            var file_reader = file.readerStreaming(io, &file_reader_buffer);

            var buffer: std.Io.Writer.Allocating = .init(gpa);
            defer buffer.deinit();

            if (file_reader.getSize()) |size| {
                const casted_size = std.math.cast(u32, size) orelse return error.StreamTooLong;
                try buffer.ensureTotalCapacity(casted_size);
            } else |_| {
                // Do nothing.
            }

            _ = try file_reader.interface.streamRemaining(&buffer.writer);
            break :file_content try buffer.toOwnedSlice();
        };
        defer gpa.free(file_content);

        var output_slices = std.ArrayList([]const u8).empty;
        defer output_slices.deinit(gpa);

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

            try output_slices.append(gpa, file_content[content_index..fix.start]);
            if (fix.text.len > 0) {
                try output_slices.append(gpa, fix.text);
            }
            content_index = fix.end;
            total_fixes += 1;
            file_fixes += 1;
        }
        if (content_index < file_content.len - 1) {
            try output_slices.append(gpa, file_content[content_index..file_content.len]);
        }

        printer.print(.out, "{s}{d} fixes{s} applied to: {s}\n", .{
            printer.tty.ansiOrEmpty(&.{.bold}),
            file_fixes,
            printer.tty.ansiOrEmpty(&.{.reset}),
            file_path,
        });

        if (output_slices.items.len > 0) {
            const new_file = try dir.createFile(io, file_path, .{
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
        for (files) |file| try index.insert(file.pathname);
    }

    if (build_exclude_lint_paths) |files| {
        for (files) |file| try index.insert(file.pathname);
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

    for (filter_paths) |file| try index.insert(file.pathname);
    return index;
}

/// Creates and returns a bitset representing enabled rules using the fixed
/// indices in the rules array. This is what allows people to filter runs with
/// the `--rule` CLI argument.
fn enabledRules(filter_rule_ids: ?[]const []const u8) std.StaticBitSet(rules.len) {
    var bitset: std.StaticBitSet(rules.len) = .initFull();
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

/// Simple more forgiving timer for optionally timing laps in verbose mode.
const Timer = struct {
    backing: ?std.time.Timer = null,

    pub fn createStarted() Timer {
        return .{ .backing = std.time.Timer.start() catch null };
    }

    pub fn lapNanoseconds(self: *Timer) ?usize {
        return (self.backing orelse return null).lap();
    }

    pub fn lapMilliseconds(self: *Timer) ?usize {
        return (self.lapNanoseconds() orelse return null) / std.time.ns_per_ms;
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

    const Item = struct {
        name: []const u8,
        elapsed_ns: usize,

        pub fn compare(_: void, a: Item, b: Item) std.math.Order {
            return std.math.order(a.elapsed_ns, b.elapsed_ns);
        }
    };

    fn init(gpa: std.mem.Allocator) SlowestItemQueue {
        return .{ .queue = .init(gpa, {}) };
    }

    fn deinit(self: *SlowestItemQueue) void {
        self.queue.deinit();
        self.* = undefined;
    }

    fn add(self: *SlowestItemQueue, item: Item) void {
        if (self.queue.add(item)) {
            if (self.queue.count() > self.max) {
                _ = self.queue.removeMin();
            }
        } else |_| {
            // Ignore.
        }
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
        while (self.queue.removeMaxOrNull()) |item| {
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

const builtin = @import("builtin");
const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const rules = @import("rules").rules; // Generated in build_rules.zig
const rules_configs = @import("rules").rules_configs; // Generated in build_rules.zig
const rules_configs_types = @import("rules").rules_configs_types; // Generated in build_rules.zig
const Ast = std.zig.Ast;
