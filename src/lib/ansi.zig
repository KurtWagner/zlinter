//! Minimal (keep it this way) ansi helpers

// TODO: Rename to tty.zig and support windows, which requires use of SetConsoleTextAttribute
// and will then also require changing the design of how this works as we need to
// accept a writer / handle for the windows API

var config: ?std.io.tty.Config = null;

/// Returns escape sequence for given ansi codes if the platform
/// supports it (otherwise returns empty string).
///
/// This makes it safe to just call whenever writing stdout.
pub inline fn get(comptime codes: []const Codes) []const u8 {
    if (builtin.is_test) return "";

    if (config == null) {
        config = std.io.tty.detectConfig(switch (version.zig) {
            .@"0.14" => std.io.getStdOut(),
            .@"0.15" => std.fs.File.stdout(),
        });
    }

    return switch (config.?) {
        .no_color => "",
        .escape_codes => sequence(codes),
        .windows_api => |ctx| if (builtin.os.tag == .windows) windowsSequence(codes, ctx.reset_attributes) else unreachable,
    };
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

    pub fn toWindowsCode(self: @This(), reset: u16) ?u16 {
        return switch (self) {
            .reset => reset,
            .underline => null,
            .red => std.os.windows.FOREGROUND_RED,
            .bold => std.os.windows.FOREGROUND_RED | std.os.windows.FOREGROUND_GREEN | std.os.windows.FOREGROUND_BLUE | std.os.windows.FOREGROUND_INTENSITY,
            .yellow => std.os.windows.FOREGROUND_RED | std.os.windows.FOREGROUND_GREEN,
            .blue => std.os.windows.FOREGROUND_BLUE,
            .gray => null,
            .green => std.os.windows.FOREGROUND_GREEN,
            .cyan => std.os.windows.FOREGROUND_GREEN | std.os.windows.FOREGROUND_BLUE,
        };
    }
};

fn windowsSequence(comptime codes: []const Codes, reset: u16) []const u8 {
    // For now does nothing on windows - see TODO at top of file
    _ = codes;
    _ = reset;
    return "";
}

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
const version = @import("version.zig");
