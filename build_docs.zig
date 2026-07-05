//! Generates a rules zig file at build time that can be built into the linter.

pub fn main(init: std.process.Init) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const gpa = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        fatal("Expected output path and rules directory arguments", .{});
    }

    const rules_dir_path = args[1];
    const output_file_path = args[2];

    var output_file = std.Io.Dir.cwd().createFile(io, output_file_path, .{}) catch |err| {
        fatal("Unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close(io);

    var buffer: [1024]u8 = undefined;
    var writer = output_file.writer(io, &buffer);

    try writer.interface.writeAll(
        \\# zlinter rules
        \\
        \\
    );

    var rule_files: std.ArrayList([]const u8) = .empty;
    defer {
        for (rule_files.items) |file_name| gpa.free(file_name);
        rule_files.deinit(gpa);
    }

    var rules_dir = std.Io.Dir.cwd().openDir(io, rules_dir_path, .{ .iterate = true }) catch |err| {
        fatal("Unable to open rules directory '{s}': {s}", .{ rules_dir_path, @errorName(err) });
    };
    defer rules_dir.close(io);

    var walker = try rules_dir.walk(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const file_path = try std.fs.path.join(gpa, &.{ rules_dir_path, entry.path });
        errdefer gpa.free(file_path);
        try rule_files.append(gpa, file_path);
    }

    const file_names = rule_files.items;
    std.mem.sort([]const u8, file_names, {}, stringLessThan);

    var file_buffer: [2048]u8 = undefined;

    var content: std.Io.Writer.Allocating = try .initCapacity(gpa, 1024 * 1024);
    defer content.deinit();

    for (file_names) |file_name| {
        defer content.clearRetainingCapacity();

        const basename = std.fs.path.basename(file_name);
        const rule_name = basename[0 .. basename.len - ".zig".len];

        try writer.interface.writeAll("## `");
        try writer.interface.writeAll(rule_name);
        try writer.interface.writeAll("`\n\n");

        var file = try std.Io.Dir.cwd().openFile(io, file_name, .{});
        defer file.close(io);

        var reader = file.readerStreaming(io, &file_buffer);

        _ = try reader.interface.streamRemaining(&content.writer);

        try writeFileDocComments(content.written(), &writer.interface);
        try writer.interface.writeByte('\n');

        try writeFileRuleConfig(content.written(), gpa, &writer.interface);
    }

    try writer.interface.flush();

    return std.process.cleanExit(io);
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.ascii.orderIgnoreCase(lhs, rhs) == .lt;
}

fn trimCommentLine(source: []const u8) []const u8 {
    if (source.len == 0) return source;

    const start: usize = if (std.ascii.isWhitespace(source[0])) 1 else 0;
    return std.mem.trimEnd(u8, source[start..], &std.ascii.whitespace);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    const exit_code_failure = 1;
    std.process.exit(exit_code_failure);
}

fn writeFileDocComments(content: []const u8, writer: anytype) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "//!")) return;

        try writer.writeAll(trimCommentLine(line["//!".len..]));
        try writer.writeByte('\n');
    }
}

fn writeFileRuleConfig(content: []const u8, gpa: std.mem.Allocator, writer: anytype) !void {
    const sentinel = try gpa.dupeSentinel(u8, content, 0);
    defer gpa.free(sentinel);

    var tree = try Ast.parse(gpa, sentinel, .zig);
    defer tree.deinit(gpa);

    try writer.writeAll("**Config options:**\n\n");

    var config_written: bool = false;
    var struct_buffer: [2]Ast.Node.Index = undefined;
    for (tree.rootDecls()) |decl| {
        if (tree.fullVarDecl(decl)) |var_decl| {
            const name = tree.tokenSlice(var_decl.ast.mut_token + 1);
            if (!std.mem.eql(u8, name, "Config")) continue;

            const struct_init = tree.fullContainerDecl(
                &struct_buffer,
                var_decl.ast.init_node.unwrap().?,
            ).?;

            fields: for (struct_init.ast.members) |field| {
                const container_field = tree.fullContainerField(field) orelse
                    continue :fields;

                try writer.writeAll("* `");
                try writer.writeAll(tree.tokenSlice(container_field.ast.main_token));
                try writer.writeAll("`");

                try writer.writeAll("\n\n  * ");
                const end = container_field.firstToken();
                var start = end;
                while (tree.tokens.items(.tag)[start - 1] == .doc_comment) {
                    if (start == 0) break;
                    start -= 1;
                }
                while (start < end) : (start += 1) {
                    try writer.writeAll(trimCommentLine(tree.tokenSlice(start)["///".len..]));
                    if (start < end - 1) {
                        try writer.writeByte(' ');
                    }
                }

                const maybe_default: ?[]const u8 = if (container_field.ast.value_expr.unwrap()) |default_node|
                    tree.getNodeSource(default_node)
                else
                    null;

                if (maybe_default) |default| {
                    try writer.writeAll("\n\n  * **Default:** `");
                    try writeWithoutDuplicateWhiteSpace(default, writer);
                    try writer.writeByte('`');
                }

                try writer.writeAll("\n\n");

                config_written = true;
            }
        }
    }
    if (!config_written) @panic("Config missing");
}

fn writeWithoutDuplicateWhiteSpace(content: []const u8, writer: anytype) !void {
    var prev_whitespace: bool = false;
    for (content) |c| {
        const is_whitespace = std.ascii.isWhitespace(c);

        if (!is_whitespace) {
            try writer.writeByte(c);
            prev_whitespace = false;
        } else if (!prev_whitespace) {
            try writer.writeByte(' ');
            prev_whitespace = true;
        }
    }
}

const std = @import("std");
const Ast = std.zig.Ast;
