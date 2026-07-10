const default_formatter = zlinter.formatters.DefaultFormatter{};

pub fn runLintMode(
    runtime: *const LintRuntime,
    args: zlinter.Args,
    printer: *zlinter.rendering.Printer,
    lint_files: []const zlinter.files.LintFile,
) !ExitCode {
    var total_fixes: usize = 0;
    const result = result: {
        var remaining_fix_passes = @max(1, args.fix_passes);
        while (remaining_fix_passes > 0)
            if (runLint(
                runtime,
                args,
                printer,
                lint_files,
            )) |r| {
                total_fixes += r.fixes_applied;
                if (r.fixes_applied == 0 or remaining_fix_passes == 1)
                    break :result r
                else {
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
            };
        unreachable;
    };
    if (total_fixes > 0)
        printer.print(
            .out,
            "{s}Total of {d} issues fixed{s}\n",
            .{
                printer.tty.ansiOrEmpty(&.{ .bold, .underline }),
                total_fixes,
                printer.tty.ansiOrEmpty(&.{.reset}),
            },
        );
    try printer.flush();

    return result.exit_code;
}

fn runLint(
    runtime: *const LintRuntime,
    args: zlinter.Args,
    printer: *zlinter.rendering.Printer,
    lint_files: []const zlinter.files.LintFile,
) !RunResult {
    var file_lint_problems = std.array_hash_map.Auto(
        zlinter.session.FileStore.FileId,
        []zlinter.results.LintResult,
    ).empty;

    var session: zlinter.session.LintSession = .{
        .runtime = runtime,
        .file_store = .init(runtime),
        .module_store = .init(runtime),
        .build_config_store = .init(runtime),
        .type_store = .init(runtime),
        .decl_store = .init(runtime),
    };
    try session.init();

    // Resolve the files to be linted once at the start and pass around file
    // ids to linting, fixing and rendering phases instead of absolute path.
    var lint_file_ids = std.ArrayList(zlinter.session.FileStore.FileId).initCapacity(
        runtime.sessionArena(),
        lint_files.len,
    ) catch @panic("OOM");
    for (lint_files) |file| {
        if (file.excluded) continue;

        if (session.file_store.resolve(file.abs_path)) |file_id| {
            if (session.file_store.fileSource(file_id).len > 0)
                lint_file_ids.appendAssumeCapacity(file_id);
        } else |e| printer.println(.err, "Unable to open file: {s} ({s})", .{ runtime.cwd, @errorName(e) });
    }

    try runLinterRules(
        &session,
        lint_file_ids.items,
        printer,
        &file_lint_problems,
        args,
    );

    printer.printBanner(.verbose);
    printer.println(.verbose, "Linted {d} files", .{lint_files.len});
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
    file_lint_problems: *std.array_hash_map.Auto(
        zlinter.session.FileStore.FileId,
        []zlinter.results.LintResult,
    ),
    args: zlinter.Args,
) !void {
    const runtime = session.runtime;

    var enabled_rules = enabledRules(args.rules);

    var cli_lint_config_store: CliLintConfigStore = .init(
        runtime.sessionArena(),
        lint_builtin.rule_configs[0..],
        lint_builtin.rules[0..],
    );
    var lint_config_store = cli_lint_config_store.store();

    files: for (lint_file_ids, 0..) |file_id, i| {
        defer runtime.resetFileArena();

        const file_abs_path = session.file_store.fileAbsPath(file_id);
        printer.println(.verbose, "[{d}/{d}] Linting: {s}", .{ i + 1, lint_file_ids.len, file_abs_path });

        try lint_config_store.index(
            runtime.io,
            runtime.sessionArena(),
            std.Io.Dir.path.dirname(file_abs_path).?,
            std.Io.Dir.cwd(),
        );

        var doc: zlinter.session.LintDocument = undefined;
        session.initDocument(file_id, runtime.fileArena(), &doc) catch |e| {
            printer.println(.err, "Unable to open file: {s} ({s})", .{ file_abs_path, @errorName(e) });
            continue :files;
        };

        printer.println(.verbose, "  - Load document:", .{});
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
        session.resolveFileTypes(file_id);
        printer.println(.verbose, "  - Rules", .{});

        var rule_it = enabled_rules.iterator(.{ .direction = .forward, .kind = .set });
        while (rule_it.next()) |rule_index| {
            defer runtime.resetRuleArena();

            const rule_idx: zlinter.rules.RuleIndex = @enumFromInt(rule_index);

            const rule = lint_builtin.rules[@intFromEnum(rule_idx)];
            const rule_zone = tracy.traceNamed(@src(), "cli.rule");
            defer rule_zone.end();
            rule_zone.addText(rule.rule_id);
            rule_zone.addText(file_abs_path);
            if (try rule.run(
                rule,
                session,
                &doc,
                .{
                    .config = lint_config_store.lookup(
                        std.Io.Dir.path.dirname(file_abs_path).?,
                        rule_idx,
                    ),
                },
            )) |result|
                appendDedupedResult(
                    runtime.sessionArena(),
                    &results,
                    &doc,
                    result,
                );
        }

        if (results.items.len > 0)
            oom(file_lint_problems.putNoClobber(
                runtime.sessionArena(),
                file_id,
                oom(results.toOwnedSlice(runtime.sessionArena())),
            ));
    }
}

fn appendDedupedResult(
    session_arena: std.mem.Allocator,
    results: *std.ArrayList(zlinter.results.LintResult),
    doc: *zlinter.session.LintDocument,
    result: zlinter.results.LintResult,
) void {
    var deduped_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    for (result.problems) |problem| {
        var deduped_problem = problem;
        deduped_problem.disabled_by_comment = doc.shouldSkipProblem(deduped_problem);

        if (containsEquivalentProblem(results.items, deduped_problem)) continue;
        if (containsEquivalentProblemInSlice(deduped_problems.items, deduped_problem)) continue;

        oom(deduped_problems.append(session_arena, deduped_problem));
    }

    if (deduped_problems.items.len == 0) return;

    oom(results.append(session_arena, .{
        .file_id = result.file_id,
        .problems = oom(deduped_problems.toOwnedSlice(session_arena)),
    }));
}

fn containsEquivalentProblem(
    results: []const zlinter.results.LintResult,
    problem: zlinter.results.LintProblem,
) bool {
    for (results) |result| for (result.problems) |existing_problem|
        if (existing_problem.isEquivalent(problem)) return true;
    return false;
}

fn containsEquivalentProblemInSlice(
    problems: []const zlinter.results.LintProblem,
    problem: zlinter.results.LintProblem,
) bool {
    for (problems) |existing_problem|
        if (existing_problem.isEquivalent(problem)) return true;
    return false;
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
        for (results) |result|
            problems: for (result.problems) |problem| {
                if (problem.disabled_by_comment) continue :problems;
                switch (problem.severity) {
                    .@"error" => run_result = .lint_error,
                    .warning => warning_count += 1,
                    .off => {},
                }
            };
    }
    // zlinter-disable-next-line require_braces
    if (max_warnings) |max| {
        if (warning_count > max)
            run_result = .lint_error;
    }

    var flattened = try std.ArrayList(zlinter.results.LintResult).initCapacity(
        session_arena,
        results_count,
    );
    for (file_lint_problems.values()) |results|
        flattened.appendSliceAssumeCapacity(results);

    try formatter.format(.{
        .results = try flattened.toOwnedSlice(session_arena),
        .file_store = &session.file_store,
        .runtime = runtime,
        .tty = output_tty,
        .min_severity = if (quiet) .@"error" else .warning,
    }, output_writer);

    return run_result;
}

fn allocCwdRelPath(
    // TODO: #164  Use arena
    gpa: std.mem.Allocator,
    cwd: []const u8,
    abs_path: []const u8,
) ![]const u8 {
    return std.Io.Dir.path.relative(gpa, cwd, null, cwd, abs_path);
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
        for (results) |result|
            problems: for (result.problems) |err| {
                if (err.disabled_by_comment) {
                    total_disabled_by_comment += 1;
                    continue :problems;
                }

                if (err.fix) |fix|
                    try lint_fixes.append(runtime.sessionArena(), fix);
            };

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
        fixes: for (lint_fixes.items) |fix| {
            if (previous_fix) |p|
                if (fix.start <= p.end) {
                    // Skip this fix as it collides with previous fixes range
                    // and may cause an invalid result.
                    continue :fixes;
                };
            previous_fix = fix;

            oom(output_slices.append(runtime.fileArena(), file_content[content_index..fix.start]));
            if (fix.text.len > 0)
                oom(output_slices.append(runtime.fileArena(), fix.text));
            content_index = fix.end;
            total_fixes += 1;
            file_fixes += 1;
        }
        if (content_index < file_content.len - 1)
            oom(output_slices.append(runtime.fileArena(), file_content[content_index..file_content.len]));

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
            for (output_slices.items) |output_slice|
                try writer.interface.writeAll(output_slice);
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

/// Creates and returns a bitset representing enabled rules using the fixed
/// indices in the rules array. This is what allows people to filter runs with
/// the `--rule` CLI argument.
fn enabledRules(
    filter_rule_ids: ?[]const []const u8,
) std.bit_set.Static(lint_builtin.rules.len) {
    var bitset: std.bit_set.Static(lint_builtin.rules.len) = .full;
    if (filter_rule_ids == null) return bitset;

    bitset.toggleAll();
    for (lint_builtin.rules, 0..) |rule, i| {
        var matched = false;
        for (filter_rule_ids.?) |filter_id|
            if (std.mem.eql(u8, rule.rule_id, filter_id)) {
                matched = true;
                break;
            };

        if (matched)
            bitset.set(i);
    }
    return bitset;
}

const RunResult = struct {
    exit_code: ExitCode,
    fixes_applied: usize = 0,

    const success: RunResult = .{ .exit_code = .success };
    const tool_error: RunResult = .{ .exit_code = .tool_error };
    const lint_error: RunResult = .{ .exit_code = .lint_error };
};

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const ExitCode = @import("../common.zig").ExitCode;
const lint_builtin = @import("lint_builtin");
const CliLintConfigStore = @import("../common/CliLintConfigStore.zig");

const Ast = std.zig.Ast;
const oom = zlinter.allocations.oom;
const LintRuntime = zlinter.session.LintRuntime;
const tracy = zlinter.tracy;
