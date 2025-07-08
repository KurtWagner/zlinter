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
    {
        var i: usize = 2;
        while (i < args.len) : (i += 2) {
            const arg = args[i];
            const config = args[i + 1];
            _ = config;

            try output_file.writeAll(
                try std.fmt.bufPrint(&buffer, "@import(\"{s}\").buildRule(.{{}}),\n", .{arg}),
            );
        }
    }

    try output_file.writeAll(
        \\};
        \\
        \\pub const configs = struct {
        \\
    );

    {
        var i: usize = 2;
        while (i < args.len) : (i += 2) {
            const arg = args[i];
            const config = args[i + 1];

            try output_file.writeAll(
                try std.fmt.bufPrint(&buffer, "pub const @\"{s}\": @import(\"{s}\").Config = {s};\n", .{ arg, arg, config }),
            );
        }
    }

    try output_file.writeAll(
        \\};
        \\
    );

    return std.process.cleanExit();
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    const exit_code_failure = 1;
    std.process.exit(exit_code_failure);
}

const std = @import("std");
