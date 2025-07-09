const max_file_size_bytes = bytes: {
    const bytes_in_mb = 1024 * 1024;
    break :bytes 1024 * bytes_in_mb;
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const default_formatter = zlinter.formatters.DefaultFormatter{};

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

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !u8 {
    var timer = Timer.createStarted();
    var total_timer = Timer.createStarted();

    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) @panic("Memory leak");
    };

    const args = args: {
        const raw_args = try std.process.argsAlloc(gpa);
        defer std.process.argsFree(gpa, raw_args);

        break :args zlinter.Args.allocParse(raw_args, &rules, gpa) catch |e| switch (e) {
            error.InvalidArgs => return ExitCode.usage_error.int(),
            error.OutOfMemory => return e,
        };
    };
    defer args.deinit(gpa);

    // Technically a chicken and egg problem as you can't rely on verbose stdout
    // while parsing args, so this would probably be better as a build option
    // but for now this should be fine and keeps args together at runtime...
    zlinter.rendering.process_printer.verbose = args.verbose;
    var printer = zlinter.rendering.process_printer;

    if (args.unknown_args) |unknown_args| {
        for (unknown_args) |arg|
            printer.println(.err, "Unknown argument: {s}", .{arg});
        return ExitCode.usage_error.int(); // TODO: Print help docs.
    }

    // Key is file path and value are errors for the file.
    var file_lint_problems = std.StringArrayHashMap(
        []zlinter.results.LintResult,
    ).init(gpa);
    defer {
        var it = file_lint_problems.iterator();
        while (it.next()) |entry| {
            const file_path = entry.key_ptr.*;
            const results = entry.value_ptr.*;

            for (results) |*result| result.deinit(gpa);

            gpa.free(results);
            gpa.free(file_path);
        }
        file_lint_problems.deinit();
    }

    // ------------------------------------------------------------------------
    // Resolve files then apply excludes and filters
    // ------------------------------------------------------------------------

    var dir = try std.fs.cwd().openDir("./", .{ .iterate = true });
    defer dir.close();

    const lint_files = try zlinter.files.allocLintFiles(
        dir,
        // `--include` argument supersedes build defined includes and excludes
        args.include_paths orelse args.build_include_paths orelse null,
        gpa,
    );
    defer {
        for (lint_files) |*lint_file| lint_file.deinit(gpa);
        gpa.free(lint_files);
    }

    if (try buildExcludesIndex(gpa, dir, args)) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = index.contains(file.pathname);
    }

    if (try buildFilterIndex(gpa, dir, args)) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = !index.contains(file.pathname);
    }

    if (timer.lapMilliseconds()) |ms| printer.println(.verbose, "Resolving {d} files took: {d}ms", .{ lint_files.len, ms });

    var ctx: zlinter.session.LintContext = undefined;
    try ctx.init(.{
        .zig_exe_path = args.zig_exe,
        .zig_lib_path = args.zig_lib_directory,
        .global_cache_path = args.global_cache_root,
    }, gpa);
    defer ctx.deinit();

    // ------------------------------------------------------------------------
    // Process files and populate results:
    // ------------------------------------------------------------------------

    defer {
        printer.printBanner(.verbose);
        printer.println(.verbose, "Linted {d} files", .{lint_files.len});
        if (total_timer.lapMilliseconds()) |ms| printer.println(.verbose, "Took {d}ms", .{ms});
        printer.printBanner(.verbose);
    }

    var maybe_slowest_files = if (args.verbose) SlowestItemQueue.init(gpa) else null;
    defer if (maybe_slowest_files) |*slowest_files| {
        defer slowest_files.deinit();
        slowest_files.unloadAndPrint("Files", printer);
    };

    var maybe_rule_elapsed_times = if (args.verbose)
        std.StringHashMap(u64).init(gpa)
    else
        null;
    defer if (maybe_rule_elapsed_times) |*e| e.deinit();
    defer if (maybe_rule_elapsed_times) |*rule_elapsed_times| {
        var item_timers = SlowestItemQueue.init(gpa);
        defer item_timers.deinit();

        var it = rule_elapsed_times.iterator();
        while (it.next()) |e| {
            item_timers.add(.{
                .name = e.key_ptr.*,
                .elapsed_ns = e.value_ptr.*,
            });
        }
        item_timers.unloadAndPrint("Rules", printer);
    };

    for (lint_files, 0..) |lint_file, i| {
        if (lint_file.excluded) {
            printer.println(.verbose, "[{d}/{d}] Excluding: {s}", .{ i + 1, lint_files.len, lint_file.pathname });
            continue;
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

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var doc = try ctx.loadDocument(lint_file.pathname, ctx.gpa, arena_allocator) orelse {
            printer.println(.err, "Unable to open file: {s}", .{lint_file.pathname});
            continue;
        };
        defer doc.deinit(ctx.gpa);
        if (timer.lapMilliseconds()) |ms|
            printer.println(.verbose, "  - Load document: {d}ms", .{ms})
        else
            printer.println(.verbose, "  - Load document", .{});
        printer.println(.verbose, "    - {d} bytes", .{doc.handle.tree.source.len});
        printer.println(.verbose, "    - {d} nodes", .{doc.handle.tree.nodes.len});
        printer.println(.verbose, "    - {d} tokens", .{doc.handle.tree.tokens.len});

        var results = std.ArrayListUnmanaged(zlinter.results.LintResult).empty;
        defer results.deinit(gpa);

        const ast = doc.handle.tree;
        for (ast.errors) |err| {
            const position = ast.tokenLocation(
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
                            .offset = position.line_start,
                            .line = position.line,
                            .column = position.column,
                        },
                        .end = .{
                            .offset = position.line_end,
                            .line = position.line,
                            .column = position.column + ast.tokenSlice(err.token).len - 1,
                        },
                        .message = try allocAstErrorMsg(ast, err, gpa),
                    }}),
                },
            );
        }
        if (timer.lapMilliseconds()) |ms| printer.println(.verbose, "  - Process syntax errors: {d}ms", .{ms});

        const disable_comments = try zlinter.comments.allocParse(ast.source, gpa);
        defer {
            for (disable_comments) |*dc| dc.deinit(gpa);
            gpa.free(disable_comments);
        }
        if (timer.lapMilliseconds()) |ms| printer.println(.verbose, "  - Parsing doc comments: {d}ms", .{ms});

        var rule_filter_map = map: {
            var map = std.StringHashMapUnmanaged(void).empty;
            if (args.rules) |filter_rules| {
                for (filter_rules) |rule| {
                    try map.put(gpa, rule, {});
                }
                break :map map;
            }
            break :map null;
        };
        defer if (rule_filter_map) |*m| m.deinit(gpa);

        printer.println(.verbose, "  - Rules", .{});
        for (rules) |rule| {
            if (rule_filter_map) |map|
                if (!map.contains(rule.rule_id)) continue;

            const rule_result = try rule.run(
                rule,
                ctx,
                doc,
                gpa,
                .{
                    .config = config: {
                        inline for (@typeInfo(configs).@"struct".decls) |decl| {
                            if (std.mem.eql(u8, rule.rule_id, decl.name)) {
                                break :config @as(*anyopaque, @constCast(&@field(configs, decl.name)));
                            }
                        }
                        printer.println(.err, "Failed to lookup rule config for {s}", .{rule.rule_id});
                        @panic("Failed to find rule config");
                    },
                },
            );

            if (rule_result) |result| {
                for (result.problems) |*err| {
                    err.disabled_by_comment = shouldSkip(disable_comments, err.*);
                }
                try results.append(gpa, result);
            }

            if (timer.lapNanoseconds()) |ns| {
                if (maybe_rule_elapsed_times) |*rule_elapsed_time| {
                    if (rule_elapsed_time.getPtr(rule.rule_id)) |elapsed_ns| {
                        elapsed_ns.* += ns;
                    } else {
                        rule_elapsed_time.put(rule.rule_id, ns) catch {};
                    }
                }

                printer.println(.verbose, "    - {s}: {d}ms", .{ rule.rule_id, ns / std.time.ns_per_ms });
            } else printer.println(.verbose, "    - {s}", .{rule.rule_id});
        }

        if (results.items.len > 0) {
            try file_lint_problems.putNoClobber(
                try gpa.dupe(u8, lint_file.pathname),
                try results.toOwnedSlice(gpa),
            );
        }
    }

    // ------------------------------------------------------------------------
    // Print out results:
    // ------------------------------------------------------------------------

    const output_writer = std.io.getStdOut().writer();
    if (args.fix) {
        var total_fixes: usize = 0;
        var total_disabled_by_comment: usize = 0;

        var it = file_lint_problems.iterator();
        while (it.next()) |entry| {
            var lint_fixes = std.ArrayListUnmanaged(zlinter.results.LintProblemFix).empty;
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

            const file_path = entry.key_ptr.*;
            const file = try dir.openFile(file_path, .{
                .mode = .read_only,
            });
            defer file.close();

            const file_content = try file.reader().readAllAlloc(gpa, max_file_size_bytes);
            defer gpa.free(file_content);

            var output_slices = std.ArrayListUnmanaged([]const u8).empty;
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

            try output_writer.print("{d} fixes applied to: {s}\n", .{
                file_fixes,
                file_path,
            });

            if (output_slices.items.len > 0) {
                const new_file = try dir.createFile(file_path, .{
                    .truncate = true,
                });
                defer new_file.close();

                var writer = new_file.writer();
                for (output_slices.items) |output_slice| {
                    try writer.writeAll(output_slice);
                }
            }
        }

        try output_writer.print(
            "Fixed {d} issues in {d} files!\n{d} issues disabled by comments.\n",
            .{
                total_fixes,
                file_lint_problems.count(),
                total_disabled_by_comment,
            },
        );
        return ExitCode.success.int();
    } else {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var flattened = std.ArrayListUnmanaged(zlinter.results.LintResult).empty;
        for (file_lint_problems.values()) |results| {
            try flattened.appendSlice(arena_allocator, results);
        }

        const exit_code = exit_code: {
            for (flattened.items) |result| {
                for (result.problems) |problem| {
                    if (problem.severity == .@"error" and !problem.disabled_by_comment) {
                        break :exit_code ExitCode.lint_error.int();
                    }
                }
            }
            break :exit_code ExitCode.success.int();
        };

        const formatter = switch (args.format) {
            .default => &default_formatter.formatter,
        };
        try formatter.format(.{
            .results = try flattened.toOwnedSlice(arena_allocator),
            .dir = dir,
            .arena = arena_allocator,
        }, &output_writer);

        return exit_code;
    }
}

fn cmpFix(context: void, a: zlinter.results.LintProblemFix, b: zlinter.results.LintProblemFix) bool {
    return std.sort.asc(@TypeOf(a.start))(context, a.start, b.start);
}

/// Allocates an AST error into a string.
///
/// The returned string must be freed by the caller. i.e., allocator.free(error_message);
fn allocAstErrorMsg(
    ast: std.zig.Ast,
    err: std.zig.Ast.Error,
    allocator: std.mem.Allocator,
) error{OutOfMemory}![]const u8 {
    var error_message = std.ArrayListUnmanaged(u8).empty;
    defer error_message.deinit(allocator);

    try ast.renderError(err, error_message.writer(allocator));
    return error_message.toOwnedSlice(allocator);
}

/// An unoptimized algorithm that checks whether a given rule has been disabled
/// by a comment in the same source file. If files have a lot of disable
/// comments this algorithm may become a problem (but a lot of disables is an
/// anti pattern so probably ok?)
///
/// Returns true if a lint error should be skipped / ignored due to a comment
/// in the source code.
fn shouldSkip(disable_comments: []zlinter.comments.LintDisableComment, err: zlinter.results.LintProblem) bool {
    for (disable_comments) |comment| {
        if (comment.line_start <= err.start.line and err.start.line <= comment.line_end) {
            // When there's no explicity rules set, we disable for all rules.
            if (comment.rule_ids.len == 0) return true;

            // Otherwise, we only disable for explicitly given rules.
            for (comment.rule_ids) |rule_id| {
                if (std.mem.eql(u8, rule_id, err.rule_id)) {
                    return true;
                }
            }
        }
    }
    return false;
}

// TODO: Could do with being moved to lib and having tests written for it

/// Returns an index of files to exclude if exclude configuration is found in args
fn buildExcludesIndex(gpa: std.mem.Allocator, dir: std.fs.Dir, args: zlinter.Args) !?std.BufSet {
    if (args.exclude_paths == null and args.build_exclude_paths == null) return null;

    const exclude_lint_paths: ?[]zlinter.files.LintFile = exclude: {
        if (args.exclude_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(dir, p, gpa);
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

        if (args.build_exclude_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(dir, p, gpa);
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

// TODO: Could do with being moved to lib and having tests written for it
/// Returns an index of files to only include if filter configuration is found in args
fn buildFilterIndex(gpa: std.mem.Allocator, dir: std.fs.Dir, args: zlinter.Args) !?std.BufSet {
    const filter_paths: []zlinter.files.LintFile = exclude: {
        if (args.filter_paths) |p| {
            std.debug.assert(p.len > 0);
            break :exclude try zlinter.files.allocLintFiles(dir, p, gpa);
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

/// Simple more forgiving timer for optionally timing laps in verbose mode.
const Timer = struct {
    backing: ?std.time.Timer = null,

    pub fn createStarted() Timer {
        return .{ .backing = std.time.Timer.start() catch null };
    }

    pub fn lapNanoseconds(self: *Timer) ?u64 {
        return (self.backing orelse return null).lap();
    }

    pub fn lapMilliseconds(self: *Timer) ?u64 {
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
        elapsed_ns: u64,

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
        } else |_| {}
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
                zlinter.ansi.get(&.{.bold}),
                item.elapsed_ns / std.time.ns_per_ms,
                zlinter.ansi.get(&.{.reset}),
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
const builtin = @import("builtin");
const zlinter = @import("zlinter");
const rules = @import("rules").rules; // Generated in build.zig
const configs = @import("rules").configs; // Generated in build.zig
