//! Module containing methods for extracting lint relevant comments from source files.
//!
//! These comments can alter the behaviour of the linter. e.g., a comment may disable a specific rule on a specific line.

const std = @import("std");

pub const DocumentComments = struct {
    disable_comments: []LintDisableComment,
    todo_comments: []TodoComment,

    pub fn deinit(self: *DocumentComments, gpa: std.mem.Allocator) void {
        for (self.disable_comments) |*d| d.deinit(gpa);
        gpa.free(self.disable_comments);
        gpa.free(self.todo_comments);

        self.* = undefined;
    }
};

/// Represents a comment that disables some lint rules within a line range
/// of a given source file.
pub const LintDisableComment = struct {
    const Self = @This();

    /// Line of source (index zero) to disable rules from (inclusive).
    line_start: usize,

    /// Line of source (index zero) to disable rules to (inclusive).
    line_end: usize,

    /// Rules to disable, if empty, it means, disable all rules.
    /// Rule ids are slices of the source and thus do not need to be freed
    /// but disappear if the source does.
    rule_ids: []const []const u8,

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.rule_ids);
    }
};

/// Represents a comment in the source file that starts with "todo" case insensitive
/// Todo comments are single line.
pub const TodoComment = struct {
    const Location = struct {
        /// Location in entire source (inclusive)
        byte_offset: usize,
        /// Line number in source (index zero)
        line: usize,
        /// Column on line in source (index zero)
        column: usize,
    };

    /// Inclusive start of the todo comments contents to the source
    start: Location,
    /// Inclusive end of the todo comments contents to the source
    end: Location,

    pub inline fn getContentsSlice(self: TodoComment, source: [:0]const u8) []const u8 {
        return source[self.start.byte_offset .. self.end.byte_offset + 1];
    }
};

/// Parses a given source file and returns an allocated array of disable lint
/// comments.
///
/// Comments must be freed using `comments.deinit(gpa)`
pub fn allocParse(source: [:0]const u8, gpa: std.mem.Allocator) error{OutOfMemory}!DocumentComments {
    const State = enum {
        parsing,
        slash,
        line_comment_start,
        line_comment_start_word,
        line_comment_word,
        line_comment_end_word,
        new_line,
        disable_token_next_line,
        disable_token_current_line,
        disable_token_start,
        disable_token,
        disable_token_end,
        disable_token_rule_start,
        disable_token_rule,
        disable_token_rule_end,
        todo,
    };

    var start_index: usize = 0;
    var start_word_index: usize = 0;
    var index: usize = 0;
    var line: usize = 0;
    var line_start: usize = 0;

    var disable_token: []const u8 = "";
    var disable_token_rule_start_index: usize = 0;
    var disable_token_line: usize = 0;

    var disabled_rules = std.ArrayListUnmanaged([]const u8).empty;
    defer disabled_rules.deinit(gpa);

    var disable_comments = std.ArrayListUnmanaged(LintDisableComment).empty;
    defer disable_comments.deinit(gpa);

    var todo_comments = std.ArrayListUnmanaged(TodoComment).empty;
    defer todo_comments.deinit(gpa);

    state: switch (State.parsing) {
        .parsing => switch (source[index]) {
            0 => {},
            '/' => continue :state .slash,
            '\n' => continue :state .new_line,
            else => {
                index += 1;
                continue :state .parsing;
            },
        },
        .new_line => {
            index += 1;
            line += 1;
            line_start = index;
            continue :state .parsing;
        },
        .slash => {
            index += 1;
            switch (source[index]) {
                '/' => continue :state .line_comment_start,
                else => continue :state .parsing,
            }
        },
        .line_comment_start => {
            index += 1;
            switch (source[index]) {
                0, '\n' => continue :state .parsing,
                '/' => continue :state .line_comment_start,
                else => {
                    start_index = index;
                    continue :state .line_comment_start_word;
                },
            }
        },
        .line_comment_start_word => {
            switch (source[index]) {
                0, '\n' => continue :state .parsing,
                ' ', '\t', '\r' => {
                    index += 1;
                    continue :state .line_comment_start_word;
                },
                else => {
                    start_word_index = index;
                    continue :state .line_comment_word;
                },
            }
        },
        .line_comment_word => {
            index += 1;
            switch (source[index]) {
                0, ' ', '\t'...'\r' => {
                    continue :state .line_comment_end_word;
                },
                else => {
                    continue :state .line_comment_word;
                },
            }
        },
        .line_comment_end_word => {
            const token = source[start_word_index..index];
            if (std.mem.eql(u8, token, "zlinter-disable-next-line")) {
                continue :state .disable_token_next_line;
            } else if (std.mem.eql(u8, token, "zlinter-disable-current-line")) {
                continue :state .disable_token_current_line;
            } else if (std.ascii.eqlIgnoreCase(token, "TODO") or
                std.ascii.eqlIgnoreCase(token, "TODO:") or
                std.ascii.eqlIgnoreCase(token, "TODO-"))
            {
                index += 1;
                continue :state .todo;
            } else {
                switch (source[index]) {
                    ' ', '\t' => continue :state .line_comment_start_word,
                    else => continue :state .parsing,
                }
            }
        },
        .disable_token_next_line => {
            disable_token_line = line + 1;
            continue :state .disable_token_start;
        },
        .disable_token_current_line => {
            disable_token_line = line;
            continue :state .disable_token_start;
        },
        .disable_token_start => {
            disable_token = source[start_word_index..index];
            switch (source[index]) {
                '\n', 0 => continue :state .disable_token_end,
                else => continue :state .disable_token,
            }
        },
        .disable_token => {
            index += 1;
            switch (source[index]) {
                '\n', 0, '-' => continue :state .disable_token_end,
                '\t', ',', ' ', '\r' => continue :state .disable_token,
                else => continue :state .disable_token_rule_start,
            }
        },
        .disable_token_end => {
            try disable_comments.append(gpa, .{
                .line_start = disable_token_line,
                .line_end = disable_token_line,
                .rule_ids = try disabled_rules.toOwnedSlice(gpa),
            });
            disabled_rules.clearAndFree(gpa);

            continue :state .parsing;
        },
        .disable_token_rule_start => {
            disable_token_rule_start_index = index;
            continue :state .disable_token_rule;
        },
        .disable_token_rule => {
            index += 1;
            switch (source[index]) {
                '\n', 0, ',', ' ', '\t', '\r' => continue :state .disable_token_rule_end,
                else => continue :state .disable_token_rule,
            }
        },
        .disable_token_rule_end => {
            try disabled_rules.append(gpa, source[disable_token_rule_start_index..index]);

            switch (source[index]) {
                '\n', 0 => continue :state .disable_token_end,
                ',', ' ', '\t', '\r' => continue :state .disable_token,
                else => continue :state .disable_token_rule,
            }
        },
        .todo => {
            const start = index;
            index += 1;
            while (switch (source[index]) {
                0, '\n' => false,
                else => true,
            }) : (index += 1) {}
            try todo_comments.append(gpa, .{
                .start = .{
                    .byte_offset = start,
                    .line = line,
                    .column = start - line_start,
                },
                .end = .{
                    .byte_offset = index - 1,
                    .line = line,
                    .column = index - 1 - line_start,
                },
            });
            continue :state .parsing;
        },
    }

    return .{
        .disable_comments = try disable_comments.toOwnedSlice(gpa),
        .todo_comments = try todo_comments.toOwnedSlice(gpa),
    };
}

test "allocParse - zlinter-disable-current-line" {
    inline for (&.{ "\n", "\r\n" }) |newline| {
        var comments = try allocParse(
            "var line_0 = 0;" ++ newline ++
                "var line_1 = 0; // zlinter-disable-current-line" ++ newline ++
                "var line_2 = 0; // \t zlinter-disable-current-line  rule_a \t  rule_b " ++ newline ++
                "var line_3 = 0; // zlinter-disable-current-line rule_c - comment",
            std.testing.allocator,
        );
        defer comments.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(&.{
            LintDisableComment{
                .line_start = 1,
                .line_end = 1,
                .rule_ids = &.{},
            },
            LintDisableComment{
                .line_start = 2,
                .line_end = 2,
                .rule_ids = &.{ "rule_a", "rule_b" },
            },
            LintDisableComment{
                .line_start = 3,
                .line_end = 3,
                .rule_ids = &.{"rule_c"},
            },
        }, comments.disable_comments);
        try std.testing.expectEqual(0, comments.todo_comments.len);
    }
}

test "allocParse - zlinter-disable-next-line" {
    inline for (&.{ "\n", "\r\n" }) |newline| {
        var comments = try allocParse(
            "var line_0 = 0;" ++ newline ++
                "// \tzlinter-disable-next-line" ++ newline ++
                "var line_2 = 0;" ++ newline ++
                "//zlinter-disable-next-line \t rule_a, rule_b -  comment" ++ newline ++
                "var line_4 = 0;" ++ newline ++
                "// zlinter-disable-next-line  rule_c " ++ newline ++
                "var line_6 = 0;",
            std.testing.allocator,
        );
        defer comments.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(&.{
            LintDisableComment{
                .line_start = 2,
                .line_end = 2,
                .rule_ids = &.{},
            },
            LintDisableComment{
                .line_start = 4,
                .line_end = 4,
                .rule_ids = &.{ "rule_a", "rule_b" },
            },
            LintDisableComment{
                .line_start = 6,
                .line_end = 6,
                .rule_ids = &.{"rule_c"},
            },
        }, comments.disable_comments);
        try std.testing.expectEqual(0, comments.todo_comments.len);
    }
}

test "allocParse - tode" {
    var comments = try allocParse(
        \\var line_0 = 0;
        \\// todo a b c
        \\var line_2 = 0;
        \\// TODO: c b a
        \\var line_4 = 0;
        \\//TODO- e f g
        \\var line_6 = 0;
    ,
        std.testing.allocator,
    );
    defer comments.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(&.{
        TodoComment{
            .start = .{
                .byte_offset = 24,
                .line = 1,
                .column = 8,
            },
            .end = .{
                .byte_offset = 28,
                .line = 1,
                .column = 12,
            },
        },
        TodoComment{
            .start = .{
                .byte_offset = 55,
                .line = 3,
                .column = 9,
            },
            .end = .{
                .byte_offset = 59,
                .line = 3,
                .column = 13,
            },
        },
        TodoComment{
            .start = .{
                .byte_offset = 85,
                .line = 5,
                .column = 8,
            },
            .end = .{
                .byte_offset = 89,
                .line = 5,
                .column = 12,
            },
        },
    }, comments.todo_comments);
    try std.testing.expectEqual(0, comments.disable_comments.len);
}
