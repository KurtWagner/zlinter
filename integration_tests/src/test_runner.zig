const ansi_red_bold = "\x1B[31;1m";
const ansi_green_bold = "\x1B[32;1m";
const ansi_yellow_bold = "\x1B[33;1m";
const ansi_bold = "\x1B[1m";
const ansi_reset = "\x1B[0m";
const ansi_gray = "\x1B[90m";

pub fn main() !void {
    var mem: [32 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);
    const allocator = fba.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // First arg is executable
    // Second arg is rule name
    // Third arg is test name
    const rule_name = args[1];
    const test_name = args[2];

    const out = std.fs.File.stdout().deprecatedWriter();

    const output_fmt = ansi_gray ++
        "[Integration test]" ++
        ansi_reset ++
        " " ++
        ansi_bold ++
        "{s}" ++
        ansi_reset ++
        " - {s}{s}{s}{s}" ++
        ansi_reset;

    var pretty_name_buffer: [128]u8 = undefined;
    var test_desc_buffer: [128]u8 = undefined;
    var fail: bool = false;
    for (builtin.test_functions) |t| {
        const test_description = if (std.mem.eql(u8, test_name, rule_name))
            ""
        else
            std.fmt.bufPrint(&test_desc_buffer, "{s} - ", .{prettyName(&pretty_name_buffer, test_name)}) catch "";

        if (t.func()) {
            try std.fmt.format(out, output_fmt ++ "\n", .{
                rule_name,
                test_description,
                ansi_green_bold,
                "passed",
                ansi_reset,
            });
        } else |err| switch (err) {
            error.SkipZigTest => {
                try std.fmt.format(out, output_fmt ++ "\n", .{
                    rule_name,
                    test_description,
                    ansi_yellow_bold,
                    "skipped",
                    ansi_reset,
                });
            },
            else => {
                fail = true;
                try std.fmt.format(out, output_fmt ++ ": {}\n", .{
                    rule_name,
                    test_description,
                    ansi_red_bold,
                    "failed",
                    ansi_reset,
                    err,
                });
            },
        }
    }

    std.posix.exit(if (fail) 1 else 0);
}

fn prettyName(buffer: []u8, input: []const u8) []const u8 {
    if (input.len == 0) return "";

    buffer[0] = std.ascii.toUpper(input[0]);
    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        buffer[i] = switch (input[i]) {
            '-', '_', '.' => ' ',
            else => |c| c,
        };
    }
    return buffer[0..input.len];
}

const std = @import("std");
const builtin = @import("builtin");
