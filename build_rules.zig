//! Generates a rules zig file at build time that can be built into the linter.

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) @panic("Memory leak");

    const gpa = debug_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) fatal("Wrong number of arguments", .{});

    const output_file_path = args[1];
    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("Unable to open '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    try output_file.writeAll(
        \\const zlinter = @import("zlinter");
        \\
        \\pub const rules = [_]zlinter.LintRule{
        \\
    );
    var buffer: [2048]u8 = undefined;
    for (args[2..]) |arg| {
        try output_file.writeAll(
            try std.fmt.bufPrint(&buffer, "@import(\"{s}\").buildRule(.{{}}),\n", .{arg}),
        );
    }
    try output_file.writeAll(
        \\};
        \\
        \\pub const RulesConfig = struct {
        \\
    );

    for (args[2..]) |arg| {
        try output_file.writeAll(
            try std.fmt.bufPrint(&buffer, "@\"{s}\": @import(\"{s}\").Config = .{{}},\n", .{ arg, arg }),
        );
    }

    try output_file.writeAll(
        \\};
        \\
    );

    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

const std = @import("std");
