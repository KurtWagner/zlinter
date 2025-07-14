//! Module containing methods for extracting lint relevant comments from source files.
//!
//! These comments can alter the behaviour of the linter. e.g., a comment may disable a specific rule on a specific line.

const std = @import("std");

pub const DocumentComments = struct {
    tokens: []const Token,
    comments: []Comment,

    pub fn deinit(self: *DocumentComments, gpa: std.mem.Allocator) void {
        gpa.free(self.comments);
        gpa.free(self.tokens);
        self.* = undefined;
    }
};

/// Represents a comment in the source file
pub const Comment = struct {
    kind: union(enum) {
        // TODO: Implement this.
        standard: void,
        /// Represents a `TODO:` comment in the source tree
        todo: struct {
            /// Inclusive
            first_content: Token.Index,
            /// Inclusive
            last_content: Token.Index,
        },
        /// Represents an empty `TODO:` comment in the source tree
        todo_empty: void,
        /// Represents a comment that disables some lint rules within a line range
        /// of a given source file.
        disable: struct {
            /// Line of source (index zero) to disable rules from (inclusive).
            line_start: usize,

            /// Line of source (index zero) to disable rules to (inclusive).
            line_end: usize,

            /// Rules to disable, if empty, it means, disable all rules.
            rule_ids: ?struct {
                /// Inclusive
                first: Token.Index,
                /// Inclusive
                last: Token.Index,
            } = null,
        },
    },

    /// Inclusive
    first_token: Token.Index,

    /// Inclusive
    last_token: Token.Index,
};

const Token = struct {
    const Index = u32;

    /// Inclusive
    first_byte: usize,

    /// Inclusive
    last_byte: usize,

    line_number: usize,
    column_number: usize,
    tag: Tag,

    const Tag = enum {
        /// `///`
        doc_comment,
        /// `//!`
        file_comment,
        /// `//`
        source_comment,

        /// `TODO` or `todo`
        todo,
        /// `zlinter-disable-next-line`
        disable_lint_current_line,
        /// `zlinter-disable-current-line`
        disable_lint_next_line,
        delimiter,
        word,

        fn isComment(self: Tag) bool {
            return switch (self) {
                .doc_comment,
                .file_comment,
                .source_comment,
                => true,
                else => false,
            };
        }
    };

    inline fn getSlice(self: Token, source: []const u8) []const u8 {
        return source[self.first_byte .. self.last_byte + 1];
    }
};

pub fn allocParse(source: [:0]const u8, gpa: std.mem.Allocator) error{OutOfMemory}!DocumentComments {
    var comments = std.ArrayList(Comment).init(gpa);
    defer comments.deinit();

    var tokens = std.ArrayList(Token).init(gpa);
    defer tokens.deinit();

    {
        const State = enum {
            parsing,
            consume_comment,
            consume_newline,
            consume_forward_slash,
        };

        const Tokenizer = struct {
            i: usize = 0,
            line_start: usize = 0,
            line_number: usize = 0,

            fn column(self: @This()) usize {
                return self.i - self.line_start;
            }
        };
        var t = Tokenizer{};

        state: switch (State.parsing) {
            .parsing => switch (source[t.i]) {
                0 => {},
                '\n' => continue :state .consume_newline,
                '/' => continue :state .consume_forward_slash,
                else => {
                    t.i += 1;
                    continue :state .parsing;
                },
            },
            .consume_forward_slash => switch (source[t.i + 1]) {
                '/' => continue :state .consume_comment,
                else => {
                    t.i += 1;
                    continue :state .parsing;
                },
            },
            .consume_newline => {
                t.i += 1;
                t.line_start = t.i;
                t.line_number += 1;
                continue :state .parsing;
            },
            .consume_comment => {
                std.debug.assert(source[t.i] == '/' and source[t.i + 1] == '/');

                const tag: Token.Tag, const len: usize = switch (source[t.i + 2]) {
                    '/' => .{ .doc_comment, 3 },
                    '!' => .{ .file_comment, 3 },
                    else => .{ .source_comment, 2 },
                };

                var start = t.i;
                t.i += len;
                try tokens.append(.{
                    .tag = tag,
                    .first_byte = start,
                    .last_byte = start + len - 1,
                    .line_number = t.line_number,
                    .column_number = t.column(),
                });

                start = t.i;
                while (true) {

                    // zlinter-disable-next-line - ok
                    switch (source[t.i]) {
                        ':', '\t', ' ', 0, '\n' => |c| {
                            if (start < t.i) {
                                const token_slice = source[start..t.i];
                                try tokens.append(.{
                                    .tag = if (std.ascii.eqlIgnoreCase(token_slice, "zlinter-disable-next-line"))
                                        .disable_lint_next_line
                                    else if (std.ascii.eqlIgnoreCase(token_slice, "zlinter-disable-current-line"))
                                        .disable_lint_current_line
                                    else if (std.ascii.eqlIgnoreCase(token_slice, "TODO") or std.ascii.eqlIgnoreCase(token_slice, "TODO-"))
                                        .todo
                                    else
                                        .word,
                                    .first_byte = start,
                                    .last_byte = t.i - 1,
                                    .line_number = t.line_number,
                                    .column_number = t.column(),
                                });
                            }

                            switch (c) {
                                0, '\n' => break,
                                ':' => try tokens.append(.{
                                    .tag = .delimiter,
                                    .first_byte = t.i,
                                    .last_byte = t.i,
                                    .line_number = t.line_number,
                                    .column_number = t.column(),
                                }),
                                else => {},
                            }
                            t.i += 1;
                            start = t.i;
                        },
                        else => t.i += 1,
                    }
                }
                if (source[t.i] == '\n') continue :state .consume_newline;
            },
        }
    }

    {
        const Parser = struct {
            tokens: []const Token,
            i: Token.Index = 0,

            fn peek(self: *@This()) ?Token.Index {
                if (self.i >= self.tokens.len) return null;
                return self.i;
            }

            fn next(self: *@This()) ?Token.Index {
                const token = self.peek() orelse return null;
                self.i += 1;
                return token;
            }

            fn skip(self: *@This()) void {
                _ = self.next();
            }
        };
        var p = Parser{ .tokens = tokens.items };
        tokens: while (p.next()) |token| {
            if (p.tokens[token].tag != .source_comment) continue :tokens;

            const first_token = p.next() orelse break :tokens;

            var comment: Comment = .{
                .first_token = first_token,
                .last_token = undefined, // Set last
                .kind = undefined, // Set below
            };

            switch (p.tokens[first_token].tag) {
                .disable_lint_current_line,
                .disable_lint_next_line,
                => {
                    var maybe_first_rule_token: ?Token.Index = null;
                    var maybe_last_rule_token: ?Token.Index = null;

                    while (p.peek()) |next| {
                        switch (p.tokens[next].tag) {
                            .word => {
                                const slice = p.tokens[next].getSlice(source);
                                if (std.mem.eql(u8, slice, "-")) break;

                                if (maybe_first_rule_token == null) {
                                    maybe_first_rule_token = next;
                                }
                                maybe_last_rule_token = next;
                            },
                            .delimiter => {
                                // TODO: Add more source information here:
                                const slice = p.tokens[next].getSlice(source);
                                std.log.warn("Unexpected delimitor '{s}'. Expected a rule name", .{slice});
                            },
                            else => break,
                        }
                        p.skip();
                    }

                    const line = switch (p.tokens[first_token].tag) {
                        .disable_lint_current_line => p.tokens[first_token].line_number,
                        .disable_lint_next_line => p.tokens[first_token].line_number + 1,
                        else => unreachable,
                    };
                    comment.kind = .{
                        .disable = .{
                            .line_start = line,
                            .line_end = line,
                            .rule_ids = if (maybe_first_rule_token) |first_rule_token| .{
                                .first = first_rule_token,
                                .last = maybe_last_rule_token.?,
                            } else null,
                        },
                    };
                },
                .todo => {
                    while (p.peek()) |peek| {
                        if (p.tokens[peek].tag != .delimiter) break;
                        p.skip();
                    }
                    const first_content_token_index = p.i;

                    const maybe_last_token = token: {
                        var maybe_last_token: ?Token.Index = null;
                        while (p.peek()) |next| {
                            if (p.tokens[next].tag.isComment()) {
                                break :token maybe_last_token;
                            } else {
                                maybe_last_token = p.i;
                                p.skip();
                            }
                        }
                        break :token maybe_last_token;
                    };

                    if (maybe_last_token) |last_token_index| {
                        comment.kind = .{
                            .todo = .{
                                .first_content = first_content_token_index,
                                .last_content = last_token_index,
                            },
                        };
                    } else {
                        comment.kind = .{
                            .todo_empty = {},
                        };
                    }
                },
                else => continue :tokens,
            }

            while (p.peek()) |index| {
                if (p.tokens[index].tag.isComment()) break else p.i += 1;
            }

            comment.last_token = p.i - 1;
            try comments.append(comment);
        }
    }
    return .{
        .tokens = try tokens.toOwnedSlice(),
        .comments = try comments.toOwnedSlice(),
    };
}

// TODO: Bring back these tests:
// test "allocParse - zlinter-disable-current-line" {
//     inline for (&.{ "\n", "\r\n" }) |newline| {
//         var comments = try allocParse(
//             "var line_0 = 0;" ++ newline ++
//                 "var line_1 = 0; // zlinter-disable-current-line" ++ newline ++
//                 "var line_2 = 0; // \t zlinter-disable-current-line  rule_a \t  rule_b " ++ newline ++
//                 "var line_3 = 0; // zlinter-disable-current-line rule_c - comment",
//             std.testing.allocator,
//         );
//         defer comments.deinit(std.testing.allocator);

//         try std.testing.expectEqualDeep(&.{
//             Comment{
//                 .kind = .{
//                     .disable = .{
//                         .line_start = 1,
//                         .line_end = 1,
//                         .rule_ids = &.{},
//                     },
//                 },
//                 .start = .{
//                     .byte_offset = 34,
//                     .line = 1,
//                     .column = 18,
//                 },
//                 .end = .{
//                     .byte_offset = 62,
//                     .line = 1,
//                     .column = 46,
//                 },
//             },
//             Comment{
//                 .kind = .{
//                     .disable = .{
//                         .line_start = 2,
//                         .line_end = 2,
//                         .rule_ids = &.{ "rule_a", "rule_b" },
//                     },
//                 },
//                 .start = .{
//                     .byte_offset = 18,
//                     .line = 1,
//                     .column = 2,
//                 },
//                 .end = .{
//                     .byte_offset = 62,
//                     .line = 1,
//                     .column = 46,
//                 },
//             },
//             Comment{
//                 .kind = .{
//                     .disable = .{
//                         .line_start = 3,
//                         .line_end = 3,
//                         .rule_ids = &.{"rule_c"},
//                     },
//                 },
//                 .start = .{
//                     .byte_offset = 24,
//                     .line = 1,
//                     .column = 8,
//                 },
//                 .end = .{
//                     .byte_offset = 62,
//                     .line = 1,
//                     .column = 46,
//                 },
//             },
//         }, comments.comments);
//     }
// }

// test "allocParse - zlinter-disable-next-line" {
//     inline for (&.{ "\n", "\r\n" }) |newline| {
//         var comments = try allocParse(
//             "var line_0 = 0;" ++ newline ++
//                 "// \tzlinter-disable-next-line" ++ newline ++
//                 "var line_2 = 0;" ++ newline ++
//                 "//zlinter-disable-next-line \t rule_a, rule_b -  comment" ++ newline ++
//                 "var line_4 = 0;" ++ newline ++
//                 "// zlinter-disable-next-line  rule_c " ++ newline ++
//                 "var line_6 = 0;",
//             std.testing.allocator,
//         );
//         defer comments.deinit(std.testing.allocator);

//         try std.testing.expectEqualDeep(&.{
//             Comment{
//                 .kind = .{
//                     .disable = .{
//                         .line_start = 2,
//                         .line_end = 2,
//                         .rule_ids = &.{},
//                     },
//                 },
//                 .start = .{
//                     .byte_offset = 24,
//                     .line = 1,
//                     .column = 8,
//                 },
//                 .end = .{
//                     .byte_offset = 62,
//                     .line = 1,
//                     .column = 46,
//                 },
//             },
//             Comment{
//                 .kind = .{
//                     .disable = .{
//                         .line_start = 4,
//                         .line_end = 4,
//                         .rule_ids = &.{ "rule_a", "rule_b" },
//                     },
//                 },
//                 .start = .{
//                     .byte_offset = 24,
//                     .line = 1,
//                     .column = 8,
//                 },
//                 .end = .{
//                     .byte_offset = 62,
//                     .line = 1,
//                     .column = 46,
//                 },
//             },
//             Comment{
//                 .kind = .{
//                     .disable = .{
//                         .line_start = 6,
//                         .line_end = 6,
//                         .rule_ids = &.{"rule_c"},
//                     },
//                 },
//                 .start = .{
//                     .byte_offset = 24,
//                     .line = 1,
//                     .column = 8,
//                 },
//                 .end = .{
//                     .byte_offset = 62,
//                     .line = 1,
//                     .column = 46,
//                 },
//             },
//         }, comments.comments);
//     }
// }

// TODO: Add tests for empty comments.

test "allocParse - todo" {
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
        Comment{
            .kind = .{
                .todo = {},
            },
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
        Comment{
            .kind = .{
                .todo = {},
            },
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
        Comment{
            .kind = .{
                .todo = {},
            },
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
    }, comments.comments);
}
