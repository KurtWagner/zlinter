//! Minimal (keep it this way) ansi helpers

pub const Tty = enum {
    no_color,
    ansi_color,

    pub fn init(file: std.fs.File) Tty {
        if (builtin.is_test) return .no_color;

        return if (std.io.tty.detectConfig(file) == .escape_codes) .ansi_color else .no_color;
    }

    /// Returns the ANSI escape sequence if enabled otherwise an empty string
    pub fn ansiOrEmpty(self: Tty, comptime codes: []const AnsiCode) []const u8 {
        return switch (self) {
            .no_color => "",
            .ansi_color => comptime sequence(codes),
        };
    }
};

// Only add codes that are being used in the linter:
const AnsiCode = enum(u32) {
    reset = 0,

    bold = 1,
    underline = 4,

    red = 31,
    yellow = 33,
    blue = 34,
    gray = 90,
    green = 32,
    cyan = 36,

    fn toString(comptime self: AnsiCode) []const u8 {
        return std.fmt.comptimePrint(
            "{d}",
            .{@intFromEnum(self)},
        );
    }
};

// Private as it does not check ansi support, use get(..) instead.
inline fn sequence(comptime codes: []const AnsiCode) []const u8 {
    comptime var result: []const u8 = codes[0].toString();
    inline for (1..codes.len) |i| {
        result = result ++ ";" ++ comptime codes[i].toString();
    }
    return "\x1B[" ++ result ++ "m";
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
