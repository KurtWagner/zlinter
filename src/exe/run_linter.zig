const max_file_size_bytes = bytes: {
    const bytes_in_mb = 1024 * 1024;
    break :bytes 1024 * bytes_in_mb;
};

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
const default_formatter = zlinter.formatters.DefaultFormatter{};

const exit_codes = struct {
    const success: u8 = 0;
    const lint_error: u8 = 1;
    const usage_error: u8 = 2;
};

pub const std_options: std.Options = .{
    .log_level = .err,
};

pub fn main() !u8 {
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

        break :args try zlinter.Args.allocParse(raw_args, &rules, gpa);
    };
    defer args.deinit(gpa);

    if (args.unknown_args) |unknown_args| {
        for (unknown_args) |arg|
            std.log.err("Unknown argument: {s}\n", .{arg});
        return exit_codes.usage_error; // TODO: Print help docs.
    }

    // Key is file path and value are errors for the file.
    var file_lint_problems = std.StringArrayHashMap(
        []zlinter.LintResult,
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

    var dir = try std.fs.cwd().openDir("./", .{ .iterate = true });
    defer dir.close();

    const lint_files = try zlinter.allocLintFiles(dir, args, gpa);
    defer {
        for (lint_files) |*lint_file| lint_file.deinit(gpa);
        gpa.free(lint_files);
    }

    var ctx: zlinter.LintContext = undefined;
    try ctx.init(.{
        .zig_exe_path = args.zig_exe,
        .zig_lib_path = args.zig_lib_directory,
        .global_cache_path = args.global_cache_root,
    }, gpa);
    defer ctx.deinit();

    // ------------------------------------------------------------------------
    // Process files and populate results:
    // ------------------------------------------------------------------------

    for (lint_files) |lint_file| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var doc = try ctx.loadDocument(lint_file.pathname, ctx.gpa, arena_allocator) orelse {
            std.log.err("Unable to open file: {s}", .{lint_file.pathname});
            continue;
        };
        defer doc.deinit(ctx.gpa);

        var results = std.ArrayListUnmanaged(zlinter.LintResult).empty;
        defer results.deinit(gpa);

        const ast = doc.handle.tree;
        for (ast.errors) |err| {
            const position = ast.tokenLocation(
                0,
                err.token,
            );

            try results.append(
                gpa,
                zlinter.LintResult{
                    .file_path = try gpa.dupe(u8, lint_file.pathname),
                    .problems = try gpa.dupe(zlinter.LintProblem, &[1]zlinter.LintProblem{.{
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

        const disable_comments = try zlinter.allocParseComments(ast.source, gpa);
        defer {
            for (disable_comments) |*dc| dc.deinit(gpa);
            gpa.free(disable_comments);
        }

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
                        std.log.err("Failed to lookup rule config for {s}", .{rule.rule_id});
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
        }

        if (results.items.len > 0) {
            try file_lint_problems.putNoClobber(
                try gpa.dupe(u8, lint_file.pathname),
                try results.toOwnedSlice(gpa),
            );
        }
    }

    // ------------------------------------------------------------------------
    // Do something with results:
    // ------------------------------------------------------------------------

    const output_writer = std.io.getStdOut().writer();
    if (args.fix) {
        var total_fixes: usize = 0;
        var total_disabled_by_comment: usize = 0;

        var it = file_lint_problems.iterator();
        while (it.next()) |entry| {
            var lint_fixes = std.ArrayListUnmanaged(zlinter.LintProblemFix).empty;
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
                zlinter.LintProblemFix,
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
            var previous_fix: ?zlinter.LintProblemFix = null;
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
        return exit_codes.success;
    } else {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const arena_allocator = arena.allocator();

        var flattened = std.ArrayListUnmanaged(zlinter.LintResult).empty;
        for (file_lint_problems.values()) |results| {
            try flattened.appendSlice(arena_allocator, results);
        }

        const exit_code = exit_code: {
            for (flattened.items) |result| {
                for (result.problems) |problem| {
                    if (problem.severity == .@"error") {
                        break :exit_code exit_codes.lint_error;
                    }
                }
            }
            break :exit_code exit_codes.success;
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

fn cmpFix(context: void, a: zlinter.LintProblemFix, b: zlinter.LintProblemFix) bool {
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
fn shouldSkip(disable_comments: []zlinter.LintDisableComment, err: zlinter.LintProblem) bool {
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

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const builtin = @import("builtin");
const zlinter = @import("zlinter");
const rules = @import("rules").rules; // Generated in build.zig
const configs = @import("rules").configs; // Generated in build.zig
