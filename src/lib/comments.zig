//! Module containing methods for extracting comments from source files.
//!
//! Some comments can alter the behaviour of the linter. e.g., a comment may
//! disable a specific rule on a specific line.

const std = @import("std");

pub const DocumentComments = struct {
    tokens: []const Token,
    comments: []const Comment,

    pub fn deinit(self: *DocumentComments, gpa: std.mem.Allocator) void {
        gpa.free(self.comments);
        gpa.free(self.tokens);
        self.* = undefined;
    }
};

pub const Comment = struct {
    /// Inclusive
    first_token: Token.Index,
    /// Inclusive
    last_token: Token.Index,
    kind: Kind,

    const Kind = union(enum) {
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

        /// Represents an empty `// TODO:` comment in the source tree
        todo_empty: void,

        /// Represents a `// TODO: <content>` comment in the source tree
        todo: struct {
            /// Inclusive
            first_content: Token.Index,
            /// Inclusive
            last_content: Token.Index,
        },
    };
};

const Token = struct {
    const Index = u32;
    /// Inclusive
    first_byte: usize,
    len: usize,
    /// Line number in source document that this token appears on
    line_number: u32,
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

    const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "zlinter-disable-next-line", .disable_lint_next_line },
        .{ "zlinter-disable-current-line", .disable_lint_current_line },
        .{ "todo", .todo },
        .{ "TODO", .todo },
        .{ "Todo", .todo },
    });

    inline fn getSlice(self: Token, source: []const u8) []const u8 {
        return source[self.first_byte .. self.first_byte + self.len];
    }
};

const Tokenizer = struct {
    /// Current byte offset in source
    i: usize = 0,

    /// Current line number (increments when seeing a new line)
    line_number: u32 = 0,
};

fn allocTokenize(source: [:0]const u8, gpa: std.mem.Allocator) error{OutOfMemory}![]const Token {
    var tokens = std.ArrayList(Token).init(gpa);
    defer tokens.deinit();

    const State = enum {
        parsing,
        consume_comment,
        consume_newline,
        consume_forward_slash,
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
            t.line_number += 1;
            continue :state .parsing;
        },
        .consume_comment => {
            std.debug.assert(source[t.i] == '/' and source[t.i + 1] == '/');

            var start = t.i;
            const tag: Token.Tag, const len: usize = switch (source[t.i + 2]) {
                '/' => .{ .doc_comment, "///".len },
                '!' => .{ .file_comment, "//!".len },
                else => .{ .source_comment, "//".len },
            };
            t.i += len;
            try tokens.append(.{
                .tag = tag,
                .first_byte = start,
                .len = len,
                .line_number = t.line_number,
            });

            start = t.i;
            while (true) switch (source[t.i]) {
                ':', '\t', ' ', '\n', '\r', 0 => |c| {
                    if (start < t.i) {
                        const token_slice = source[start..t.i];
                        try tokens.append(.{
                            .tag = Token.keywords.get(token_slice) orelse .word,
                            .first_byte = start,
                            .len = t.i - start,
                            .line_number = t.line_number,
                        });
                    }

                    switch (c) {
                        0 => break,
                        '\n' => continue :state .consume_newline,
                        ':' => try tokens.append(.{
                            .tag = .delimiter,
                            .first_byte = t.i,
                            .len = 1,
                            .line_number = t.line_number,
                        }),
                        ' ', '\t', '\r' => {},
                        else => unreachable,
                    }
                    t.i += 1;
                    start = t.i;
                },
                else => t.i += 1,
            };
        },
    }
    return tokens.toOwnedSlice();
}

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

pub fn allocParse(source: [:0]const u8, gpa: std.mem.Allocator) error{OutOfMemory}!DocumentComments {
    const tokens = try allocTokenize(source, gpa);

    var comments = std.ArrayList(Comment).init(gpa);
    defer comments.deinit();

    var p = Parser{ .tokens = tokens };
    tokens: while (p.next()) |token| {
        if (!p.tokens[token].tag.isComment()) continue :tokens;

        const first_token = p.next() orelse break :tokens;
        const maybe_kind: ?Comment.Kind = kind: switch (p.tokens[first_token].tag) {
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
                break :kind .{
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

                break :kind if (maybe_last_token) |last_token_index|
                    .{ .todo = .{
                        .first_content = first_content_token_index,
                        .last_content = last_token_index,
                    } }
                else
                    .{ .todo_empty = {} };
            },
            else => continue :tokens,
        };

        // Skip until we see another comment tag or EOF
        while (p.peek()) |index| {
            if (p.tokens[index].tag.isComment()) break else p.i += 1;
        }

        if (maybe_kind) |kind| {
            try comments.append(.{
                .first_token = first_token,
                .last_token = p.i - 1,
                .kind = kind,
            });
        }
    }

    return .{
        .tokens = tokens,
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
