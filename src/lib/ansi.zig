//! Minimal (keep it this way) ansi helpers

/// Returns escape sequence for given ansi codes if the platform
/// supports it (otherwise returns empty string).
///
/// This makes it safe to just call whenever writing stdout.
pub inline fn get(comptime codes: []const Codes) []const u8 {
    // https://no-color.org
    const no_color = no_color: {
        var mem: [1]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&mem);
        break :no_color if (std.process.getEnvVarOwned(fba.allocator(), "NO_COLOR")) |val| val.len > 0 else |e| switch (e) {
            error.OutOfMemory => true,
            error.EnvironmentVariableNotFound => false,
            error.InvalidWtf8 => unreachable,
        };
    };

    const supports_ansi = !no_color and !builtin.is_test;
    return if (supports_ansi) sequence(codes) else "";
}

// Only add codes that are being used in the linter:
const Codes = enum(u32) {
    reset = 0,

    bold = 1,
    underline = 4,

    red = 31,
    yellow = 33,
    blue = 34,
    gray = 90,
    green = 32,
    cyan = 36,
};

// Private as it does not check ansi support, use get(..) instead.
inline fn sequence(comptime codes: []const Codes) []const u8 {
    comptime var i: usize = 0;
    comptime var result: []const u8 = std.fmt.comptimePrint(
        "{d}",
        .{@intFromEnum(codes[i])},
    );
    i += 1;
    inline while (i < codes.len) : (i += 1) {
        result = std.fmt.comptimePrint(
            "{s};{d}",
            .{ result, @intFromEnum(codes[i]) },
        );
    }
    return std.fmt.comptimePrint("\x1B[{s}m", .{result});
}

test "sequence" {
    try std.testing.expectEqualStrings(
        "\x1B[1mBold\x1B[0m",
        sequence(&.{.bold}) ++ "Bold" ++ sequence(&.{.reset}),
    );
    try std.testing.expectEqualStrings(
        "\x1B[1;32;4mBold Green Underlined\x1B[0m",
        sequence(&.{ .bold, .green, .underline }) ++ "Bold Green Underlined" ++ sequence(&.{.reset}),
    );
}

const std = @import("std");
const builtin = @import("builtin");
