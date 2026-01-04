//! Generates a rules zig file at build time that can be built into the linter.

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) @panic("Memory leak");

    var threaded: std.Io.Threaded = .init_single_threaded;
    const io = threaded.io();

    const gpa = debug_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) fatal("Wrong number of arguments", .{});

    const output_file_path = args[1];
    var output_file = std.Io.Dir.cwd().createFile(io, output_file_path, .{}) catch |err| {
        fatal("Unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close(io);

    const rule_names = args[2..];

    var write_buffer: [2048]u8 = undefined;
    var output_file_writer = output_file.writer(io, &write_buffer);

    try output_file_writer.interface.writeAll(
        \\const zlinter = @import("zlinter");
        \\
        \\pub const rules = [_]zlinter.rules.LintRule{
        \\
    );

    {
        for (rule_names) |rule_name| {
            try output_file_writer.interface.print("@import(\"{s}\").buildRule(.{{}}),\n", .{rule_name});
        }
    }

    try output_file_writer.interface.writeAll(
        \\};
        \\
        \\const config_namespace = struct {
        \\
    );

    {
        for (rule_names) |rule_name| {
            try output_file_writer.interface.print("pub const @\"{s}\": @import(\"{s}\").Config = @import(\"{s}.zon\");\n", .{
                rule_name,
                rule_name,
                rule_name,
            });
        }
    }

    try output_file_writer.interface.writeAll(
        \\};
        \\
    );

    try output_file_writer.interface.writeAll(
        \\pub const rules_configs = [_]*anyopaque {
        \\
    );

    {
        for (rule_names) |rule_name| {
            try output_file_writer.interface.print("@alignCast(@ptrCast(@constCast(&@field(config_namespace, \"{s}\")))),\n", .{rule_name});
        }
    }

    try output_file_writer.interface.writeAll(
        \\};
        \\
    );

    try output_file_writer.interface.writeAll(
        \\pub const rules_configs_types = [_]type {
        \\
    );

    {
        for (rule_names) |rule_name| {
            try output_file_writer.interface.print("@import(\"{s}\").Config,\n", .{rule_name});
        }
    }

    try output_file_writer.interface.writeAll(
        \\};
        \\
    );

    try output_file_writer.interface.flush();

    return std.process.cleanExit(io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    const exit_code_failure = 1;
    std.process.exit(exit_code_failure);
}

const std = @import("std");
