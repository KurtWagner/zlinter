/// A linter rule with a unique id and a run method.
pub const LintRule = struct {
    rule_id: []const u8,
    run: *const fn (
        self: LintRule,
        doc: session.LintDocument,
        allocator: std.mem.Allocator,
        options: RunOptions,
    ) error{OutOfMemory}!?results.LintResult,
};

pub const RunOptions = struct {
    /// Configuration for the rule. See `getConfig`.
    config: ?*anyopaque = null,

    pub inline fn getConfig(self: @This(), T: type) T {
        return if (self.config) |config| @as(*T, @ptrCast(@alignCast(config))).* else T{};
    }
};

/// Rules the modify the execution of rules.
pub const RuleOptions = struct {}; // zlinter-disable-current-line

pub const LintTextOrder = enum {
    /// Any order
    off,

    /// Alphabetical order
    alphabetical_ascending,

    /// Reverse alphabetical / descending alphabetical / Z-A order,
    alphabetical_descending,

    pub inline fn name(self: LintTextOrder) []const u8 {
        return switch (self) {
            .off => @panic("Style is off so we should never call this method when off"),
            .alphabetical_ascending => "alphabetical",
            .alphabetical_descending => "reverse alphabetical",
        };
    }

    test name {
        try std.testing.expectEqualStrings("alphatical", LintTextOrder.alphabetical_ascending);
        try std.testing.expectEqualStrings("reverse alphatical", LintTextOrder.alphabetical_descending);
    }

    pub inline fn cmp(self: LintTextOrder, lhs: []const u8, rhs: []const u8) std.math.Order {
        return switch (self) {
            .off => @panic("Style is off so we should never call this method when off"),
            .alphabetical_ascending => cmpAlphabeticalAscending(lhs, rhs),
            .alphabetical_descending => cmpAlphabeticalDescending(lhs, rhs),
        };
    }

    test cmp {
        try std.testing.expectEqual(
            std.math.Order.eq,
            LintTextOrder.alphabetical_ascending.cmp("a", "a"),
        );
        try std.testing.expectEqual(
            std.math.Order.lt,
            LintTextOrder.alphabetical_ascending.cmp("ab", "ac"),
        );
        try std.testing.expectEqual(
            std.math.Order.gt,
            LintTextOrder.alphabetical_ascending.cmp("ac", "ab"),
        );

        try std.testing.expectEqual(
            std.math.Order.eq,
            LintTextOrder.alphabetical_descending.cmp("a", "a"),
        );
        try std.testing.expectEqual(
            std.math.Order.gt,
            LintTextOrder.alphabetical_descending.cmp("ab", "ac"),
        );
        try std.testing.expectEqual(
            std.math.Order.lt,
            LintTextOrder.alphabetical_descending.cmp("ac", "ab"),
        );
    }

    inline fn cmpAlphabeticalAscending(lhs: []const u8, rhs: []const u8) std.math.Order {
        return std.ascii.orderIgnoreCase(lhs, rhs);
    }

    inline fn cmpAlphabeticalDescending(lhs: []const u8, rhs: []const u8) std.math.Order {
        return cmpAlphabeticalAscending(lhs, rhs).invert();
    }
};

pub const LintTextOrderWithSeverity = struct {
    order: LintTextOrder,
    severity: LintProblemSeverity,

    pub const off = LintTextOrderWithSeverity{
        .order = .off,
        .severity = .off,
    };
};

pub const LintTextStyleWithSeverity = struct {
    style: LintTextStyle,
    severity: LintProblemSeverity,

    pub const off = LintTextStyleWithSeverity{
        .style = .off,
        .severity = .off,
    };
};

pub const LintTextStyle = enum {
    /// No style check - can be any style
    off,
    /// e.g., TitleCase
    title_case,
    /// e.g., snake_case
    snake_case,
    /// e.g., camelCase
    camel_case,
    /// e.g., MACRO_CASE (aka "upper snake case")
    macro_case,

    /// A basic check if the content is not (obviously) breaking the style convention
    ///
    /// This is imperfect as it doesn't actually check if word boundaries are
    /// correct but good enough for most cases.
    pub inline fn check(self: LintTextStyle, content: []const u8) bool {
        std.debug.assert(content.len > 0);

        return switch (self) {
            .off => true,
            .snake_case => !strings.containsUpper(content),
            .title_case => strings.isCapitalized(content) and !strings.containsUnderscore(content),
            .camel_case => !strings.isCapitalized(content) and !strings.containsUnderscore(content),
            .macro_case => !strings.containsLower(content),
        };
    }

    test "check" {
        // Off:
        inline for (&.{ "snake_case", "camelCase", "TitleCase", "a", "A" }) |content| {
            try std.testing.expect(LintTextStyle.off.check(content));
        }

        // Snake case:
        inline for (&.{ "snake_case", "a", "a_b_c" }) |content| {
            try std.testing.expect(LintTextStyle.snake_case.check(content));
        }

        // Title case:
        inline for (&.{ "TitleCase", "A", "AB" }) |content| {
            try std.testing.expect(LintTextStyle.title_case.check(content));
        }

        // Camel case:
        inline for (&.{ "camelCase", "a", "aB" }) |content| {
            try std.testing.expect(LintTextStyle.camel_case.check(content));
        }

        // Macro case:
        inline for (&.{ "MACRO_CASE", "A", "1", "1B" }) |content| {
            try std.testing.expect(LintTextStyle.macro_case.check(content));
        }
    }

    pub inline fn name(self: LintTextStyle) []const u8 {
        return switch (self) {
            .off => @panic("Style is off so we should never call this method when off"),
            .snake_case => "snake_case",
            .title_case => "TitleCase",
            .camel_case => "camelCase",
            .macro_case => "MACRO_CASE",
        };
    }
};

/// Represents a min or max length configuration, usually for fields and variable
/// declaration checks.
pub const LenAndSeverity = struct {
    /// Should always be inclusive.
    len: u16,
    severity: LintProblemSeverity,

    pub const off = LenAndSeverity{
        .len = 0,
        .severity = .off,
    };
};

pub const LintProblemSeverity = enum {
    /// Exit zero
    off,
    /// Exit zero with warning
    warning,
    /// Exit non-zero
    @"error",

    pub inline fn name(
        self: LintProblemSeverity,
        buffer: *[32]u8,
        options: struct { tty: ansi.Tty = .no_color },
    ) []const u8 {
        const prefix =
            switch (self) {
                .off => unreachable,
                .warning => options.tty.ansiOrEmpty(&.{ .bold, .yellow }),
                .@"error" => options.tty.ansiOrEmpty(&.{ .bold, .red }),
            };

        const suffix = options.tty.ansiOrEmpty(&.{.reset});

        return switch (self) {
            .off => unreachable,
            .warning => std.fmt.bufPrint(buffer, "{s}warning{s}", .{ prefix, suffix }) catch unreachable,
            .@"error" => std.fmt.bufPrint(buffer, "{s}error{s}", .{ prefix, suffix }) catch unreachable,
        };
    }
};

const ansi = @import("ansi.zig");
const results = @import("results.zig");
const session = @import("session.zig");
const std = @import("std");
const strings = @import("strings.zig");
const testing = @import("testing.zig");
