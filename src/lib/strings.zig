//! Utilities for strings

pub inline fn isCapitalized(name: []const u8) bool {
    return name.len > 0 and std.ascii.isUpper(name[0]);
}

test "isCapitalized" {
    inline for (&.{ "A", "AA", "Aa" }) |str|
        try std.testing.expect(isCapitalized(str));

    inline for (&.{ "a", "aA", "aa", "", "1A" }) |str|
        try std.testing.expect(!isCapitalized(str));
}

pub inline fn containsUnderscore(name: []const u8) bool {
    for (name) |char|
        if (char == '_') return true;
    return false;
}

test "containsUnderscore" {
    inline for (&.{ "_", "__", "a_a", "a_", "_a" }) |str|
        try std.testing.expect(containsUnderscore(str));

    inline for (&.{ "a", "", "a-" }) |str|
        try std.testing.expect(!containsUnderscore(str));
}

pub inline fn containsLower(name: []const u8) bool {
    for (name) |char|
        if (std.ascii.isLower(char)) return true;
    return false;
}

test "containsLower" {
    inline for (&.{ "a", "aA", "Aa", "1a" }) |str|
        try std.testing.expect(containsLower(str));

    inline for (&.{ "", "A", "ABC", "1", "1A", "A1" }) |str|
        try std.testing.expect(!containsLower(str));
}

pub inline fn containsUpper(name: []const u8) bool {
    for (name) |char|
        if (std.ascii.isUpper(char)) return true;
    return false;
}

test "containsUpper" {
    inline for (&.{ "A", "aA", "Aa", "1A" }) |str|
        try std.testing.expect(containsUpper(str));

    inline for (&.{ "", "a", "abc", "1" }) |str|
        try std.testing.expect(!containsUpper(str));
}

pub fn normalizeIdentifierName(name: []const u8) []const u8 {
    if (name.len <= 3) return name;

    if (name[0] == '@' and name[1] == '"' and name[name.len - 1] == '"') {
        return name[2 .. name.len - 1];
    }
    return name;
}

test "normalizeIdentifierName" {
    try std.testing.expectEqualStrings("A.b.c", normalizeIdentifierName("@\"A.b.c\""));

    inline for (&.{ "", "a", "abc", "ABC", "snake_case", "camelCase", "TitleCase" }) |str| {
        try std.testing.expectEqualStrings(str, normalizeIdentifierName(str));
    }
}

pub fn debugPrintMultilineString(source: []const u8, writer: anytype, indent: usize) void {
    var spaces: [80]u8 = @splat(' ');
    const indent_str = spaces[0..indent];

    var it = std.mem.splitScalar(u8, source, '\n');
    if (it.next()) |first_line|
        writer.print("{s}\\\\{s}", .{ indent_str, first_line });
    while (it.next()) |line|
        writer.print("\n{s}\\\\{s}", .{ indent_str, line });
}

const std = @import("std");
