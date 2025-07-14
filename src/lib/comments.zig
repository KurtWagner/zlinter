//! Module containing methods for extracting comments from source files.
//!
//! Some comments can alter the behaviour of the linter. e.g., a comment may
//! disable a specific rule on a specific line.

pub const DocumentComments = struct {
    tokens: []const Token,
    comments: []const Comment,

    pub fn deinit(self: *DocumentComments, gpa: std.mem.Allocator) void {
        gpa.free(self.comments);
        gpa.free(self.tokens);
        self.* = undefined;
    }

    pub fn debugDump(self: DocumentComments, file_path: []const u8, source: []const u8) void {
        for (self.comments) |comment| {
            switch (comment.kind) {
                .todo => |todo| {
                    std.debug.print("TODO: '{s}'\n", .{
                        source[self.tokens[todo.first_content].first_byte .. self.tokens[todo.last_content].first_byte + self.tokens[todo.last_content].len],
                    });
                },
                .todo_empty => {
                    std.debug.print("EMPTY TODO\n", .{});
                },
                .disable => |disable| {
                    std.debug.print("DISABLE:\n", .{});
                    std.debug.print(" for {s}:{d}\n", .{ file_path, disable.line_start });
                    if (disable.rule_ids) |rule_ids| {
                        for (self.tokens[rule_ids.first .. rule_ids.last + 1]) |token| {
                            std.debug.print(
                                "- {s}\n",
                                .{source[token.first_byte .. token.first_byte + token.len]},
                            );
                        }
                    }
                },
            }
            std.debug.print("Raw: '{s}'\n\n", .{source[self.tokens[comment.first_token].first_byte .. self.tokens[comment.last_token].first_byte + self.tokens[comment.last_token].len]});
        }
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

test "tokenize no comments" {
    try testTokenizer(&.{}, &.{});
    try testTokenizer(&.{""}, &.{});
    try testTokenizer(&.{"var a = 10;"}, &.{});
}

test "tokenize file comment" {
    try testTokenizer(&.{
        "//! Hello from a file comment",
        "//! that has multiple lines",
    }, &.{
        .{ 0, .file_comment, "//!" },
        .{ 0, .word, "Hello" },
        .{ 0, .word, "from" },
        .{ 0, .word, "a" },
        .{ 0, .word, "file" },
        .{ 0, .word, "comment" },
        .{ 1, .file_comment, "//!" },
        .{ 1, .word, "that" },
        .{ 1, .word, "has" },
        .{ 1, .word, "multiple" },
        .{ 1, .word, "lines" },
    });
}

test "tokenize doc comment" {
    try testTokenizer(&.{
        "/// Hello from a doc comment",
        "/// that has multiple lines",
    }, &.{
        .{ 0, .doc_comment, "///" },
        .{ 0, .word, "Hello" },
        .{ 0, .word, "from" },
        .{ 0, .word, "a" },
        .{ 0, .word, "doc" },
        .{ 0, .word, "comment" },
        .{ 1, .doc_comment, "///" },
        .{ 1, .word, "that" },
        .{ 1, .word, "has" },
        .{ 1, .word, "multiple" },
        .{ 1, .word, "lines" },
    });
}

test "tokenize disable line comments" {
    try testTokenizer(&.{
        "// zlinter-disable-current-line",
        "// zlinter-disable-current-line - has comment ",
        "// zlinter-disable-next-line rule",
        "// zlinter-disable-next-line\trule - has comment",
        "// zlinter-disable-current-line rule_1  rule_2",
        "// zlinter-disable-current-line rule_1 rule_2  -  has comment ",
    }, &.{
        .{ 0, .source_comment, "//" },
        .{ 0, .disable_lint_current_line, "zlinter-disable-current-line" },
        .{ 1, .source_comment, "//" },
        .{ 1, .disable_lint_current_line, "zlinter-disable-current-line" },
        .{ 1, .word, "-" },
        .{ 1, .word, "has" },
        .{ 1, .word, "comment" },
        .{ 2, .source_comment, "//" },
        .{ 2, .disable_lint_next_line, "zlinter-disable-next-line" },
        .{ 2, .word, "rule" },
        .{ 3, .source_comment, "//" },
        .{ 3, .disable_lint_next_line, "zlinter-disable-next-line" },
        .{ 3, .word, "rule" },
        .{ 3, .word, "-" },
        .{ 3, .word, "has" },
        .{ 3, .word, "comment" },
        .{ 4, .source_comment, "//" },
        .{ 4, .disable_lint_current_line, "zlinter-disable-current-line" },
        .{ 4, .word, "rule_1" },
        .{ 4, .word, "rule_2" },
        .{ 5, .source_comment, "//" },
        .{ 5, .disable_lint_current_line, "zlinter-disable-current-line" },
        .{ 5, .word, "rule_1" },
        .{ 5, .word, "rule_2" },
        .{ 5, .word, "-" },
        .{ 5, .word, "has" },
        .{ 5, .word, "comment" },
    });
}

test "tokenize ordinary comments" {
    try testTokenizer(&.{
        "// Hello from a source comment ",
        "// \tthat has multiple lines",
    }, &.{
        .{ 0, .source_comment, "//" },
        .{ 0, .word, "Hello" },
        .{ 0, .word, "from" },
        .{ 0, .word, "a" },
        .{ 0, .word, "source" },
        .{ 0, .word, "comment" },
        .{ 1, .source_comment, "//" },
        .{ 1, .word, "that" },
        .{ 1, .word, "has" },
        .{ 1, .word, "multiple" },
        .{ 1, .word, "lines" },
    });
}

test "tokenize todo" {
    try testTokenizer(&.{
        "//! TODO: something a ",
        "/// todo something b",
        "// Todo something c",
    }, &.{
        .{ 0, .file_comment, "//!" },
        .{ 0, .todo, "TODO" },
        .{ 0, .delimiter, ":" },
        .{ 0, .word, "something" },
        .{ 0, .word, "a" },
        .{ 1, .doc_comment, "///" },
        .{ 1, .todo, "todo" },
        .{ 1, .word, "something" },
        .{ 1, .word, "b" },
        .{ 2, .source_comment, "//" },
        .{ 2, .todo, "Todo" },
        .{ 2, .word, "something" },
        .{ 2, .word, "c" },
    });
}

fn testTokenizer(
    comptime lines: []const []const u8,
    // zlinter-disable-next-line field_naming - https://github.com/KurtWagner/zlinter/issues/59
    expected: []const struct { u32, Token.Tag, []const u8 },
) !void {
    inline for (&.{ "\n", "\r\n" }) |new_line| {
        comptime var source: [:0]const u8 = "";
        if (lines.len > 0) source = source ++ lines[0];
        if (lines.len > 1) {
            inline for (lines[1..]) |line|
                source = source ++ new_line ++ line;
        }

        const tokens = try allocTokenize(source, std.testing.allocator);
        defer std.testing.allocator.free(tokens);

        // zlinter-disable-next-line field_naming - https://github.com/KurtWagner/zlinter/issues/59
        var actual = std.ArrayList(struct { u32, Token.Tag, []const u8 }).init(std.testing.allocator);
        defer actual.deinit();
        for (tokens) |token| try actual.append(.{
            token.line_number,
            token.tag,
            token.getSlice(source),
        });

        std.testing.expectEqualDeep(expected, actual.items) catch |e| {
            std.debug.print("Expected: &.{{\n", .{});
            for (expected) |tuple| std.debug.print(
                "  .{{ {d}, .{s}, \"{s}\" }},\n",
                .{ tuple.@"0", @tagName(tuple.@"1"), tuple.@"2" },
            );
            std.debug.print("}}\n", .{});

            std.debug.print("Actual: &.{{\n", .{});
            for (actual.items) |tuple| std.debug.print(
                "  .{{ {d}, .{s}, \"{s}\" }},\n",
                .{ tuple.@"0", @tagName(tuple.@"1"), tuple.@"2" },
            );
            std.debug.print("}}\n", .{});
            return e;
        };
    }
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

const std = @import("std");
