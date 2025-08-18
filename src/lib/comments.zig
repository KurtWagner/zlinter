//! Module containing methods for extracting comments from source files.
//!
//! Some comments can alter the behaviour of the linter. e.g., a comment may
//! disable a specific rule on a specific line.

pub const Token = struct {
    pub const Index = u32;
    /// Inclusive
    first_byte: usize,
    len: usize,
    /// Line number in source document that this token appears on
    line: u32,
    tag: Tag,

    const Tag = enum {
        /// e.g., `///`
        doc_comment,
        /// e.g., `//!`
        file_comment,
        /// e.g., `//`
        source_comment,
        /// e.g., `TODO`, `Todo`, or `todo`
        todo,
        /// e.g., `zlinter-disable-next-line`
        disable_lint_current_line,
        /// e.g., `zlinter-disable-current-line`
        disable_lint_next_line,
        /// e.g., `zlinter-enable`
        enable_lint,
        /// e.g., `zlinter-disable`
        disable_lint,
        /// `:`
        colon,
        /// `(`
        open_parenthesis,
        /// `)`
        close_parenthesis,
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
        .{ "zlinter-enable", .enable_lint },
        .{ "zlinter-disable", .disable_lint },
        .{ "todo", .todo },
        .{ "TODO", .todo },
        .{ "Todo", .todo },
    });

    pub inline fn getSlice(self: Token, source: []const u8) []const u8 {
        return source[self.first_byte .. self.first_byte + self.len];
    }
};

const Tokenizer = struct {
    /// Current byte offset in source
    i: usize = 0,
    /// Current line number (increments when seeing a new line)
    line: u32 = 0,
};

/// Returns tokens and line starts (line starts inclusive zero index)
fn allocTokenize(source: [:0]const u8, gpa: std.mem.Allocator) error{OutOfMemory}!struct { []const Token, []const usize } {
    var tokens = shims.ArrayList(Token).empty;
    defer tokens.deinit(gpa);

    var line_starts = shims.ArrayList(usize).empty;
    defer line_starts.deinit(gpa);
    try line_starts.append(gpa, 0); // First line starts on byte zero

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
            t.line += 1;
            try line_starts.append(gpa, t.i);
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
            try tokens.append(gpa, .{
                .tag = tag,
                .first_byte = start,
                .len = len,
                .line = t.line,
            });

            start = t.i;
            while (true) switch (source[t.i]) {
                ':', '(', ')', '\t', ' ', '\n', '\r', 0 => |c| {
                    if (start < t.i) {
                        const token_slice = source[start..t.i];
                        try tokens.append(gpa, .{
                            .tag = Token.keywords.get(token_slice) orelse .word,
                            .first_byte = start,
                            .len = t.i - start,
                            .line = t.line,
                        });
                    }

                    switch (c) {
                        0 => break,
                        '\n' => continue :state .consume_newline,
                        ':' => try tokens.append(gpa, .{
                            .tag = .colon,
                            .first_byte = t.i,
                            .len = 1,
                            .line = t.line,
                        }),
                        ')' => try tokens.append(gpa, .{
                            .tag = .close_parenthesis,
                            .first_byte = t.i,
                            .len = 1,
                            .line = t.line,
                        }),
                        '(' => try tokens.append(gpa, .{
                            .tag = .open_parenthesis,
                            .first_byte = t.i,
                            .len = 1,
                            .line = t.line,
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
    return .{ try tokens.toOwnedSlice(gpa), try line_starts.toOwnedSlice(gpa) };
}

test "tokenize line_starts" {
    const tokens, const line_starts = try allocTokenize(
        \\var a = 1;
        \\var b = 11;
        \\var c = 123;
        \\var d = 1234;
        \\
    , std.testing.allocator);
    defer std.testing.allocator.free(tokens);
    defer std.testing.allocator.free(line_starts);

    std.testing.expectEqualDeep(&[_]usize{ 0, 11, 23, 36, 50 }, line_starts) catch |e| {
        std.debug.print("Actual: {any}\n", .{line_starts});
        return e;
    };
}

test "tokenize no comments" {
    try testTokenize(&.{}, &.{});
    try testTokenize(&.{""}, &.{});
    try testTokenize(&.{"var a = 10;"}, &.{});
}

test "tokenize file comment" {
    try testTokenize(&.{
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
    try testTokenize(&.{
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

test "tokenize disable" {
    try testTokenize(&.{
        "// zlinter-disable",
        "// zlinter-disable - has comment ",
        "// zlinter-disable rule",
        "// zlinter-disable\trule - has comment",
        "// zlinter-disable rule_1  rule_2",
        "// zlinter-disable rule_1 rule_2  -  has comment ",
    }, &.{
        .{ 0, .source_comment, "//" },
        .{ 0, .disable_lint, "zlinter-disable" },
        .{ 1, .source_comment, "//" },
        .{ 1, .disable_lint, "zlinter-disable" },
        .{ 1, .word, "-" },
        .{ 1, .word, "has" },
        .{ 1, .word, "comment" },
        .{ 2, .source_comment, "//" },
        .{ 2, .disable_lint, "zlinter-disable" },
        .{ 2, .word, "rule" },
        .{ 3, .source_comment, "//" },
        .{ 3, .disable_lint, "zlinter-disable" },
        .{ 3, .word, "rule" },
        .{ 3, .word, "-" },
        .{ 3, .word, "has" },
        .{ 3, .word, "comment" },
        .{ 4, .source_comment, "//" },
        .{ 4, .disable_lint, "zlinter-disable" },
        .{ 4, .word, "rule_1" },
        .{ 4, .word, "rule_2" },
        .{ 5, .source_comment, "//" },
        .{ 5, .disable_lint, "zlinter-disable" },
        .{ 5, .word, "rule_1" },
        .{ 5, .word, "rule_2" },
        .{ 5, .word, "-" },
        .{ 5, .word, "has" },
        .{ 5, .word, "comment" },
    });
}

test "tokenize enable" {
    try testTokenize(&.{
        "// zlinter-enable",
        "// zlinter-enable - has comment ",
        "// zlinter-enable rule",
        "// zlinter-enable\trule - has comment",
        "// zlinter-enable rule_1  rule_2",
        "// zlinter-enable rule_1 rule_2  -  has comment ",
    }, &.{
        .{ 0, .source_comment, "//" },
        .{ 0, .enable_lint, "zlinter-enable" },
        .{ 1, .source_comment, "//" },
        .{ 1, .enable_lint, "zlinter-enable" },
        .{ 1, .word, "-" },
        .{ 1, .word, "has" },
        .{ 1, .word, "comment" },
        .{ 2, .source_comment, "//" },
        .{ 2, .enable_lint, "zlinter-enable" },
        .{ 2, .word, "rule" },
        .{ 3, .source_comment, "//" },
        .{ 3, .enable_lint, "zlinter-enable" },
        .{ 3, .word, "rule" },
        .{ 3, .word, "-" },
        .{ 3, .word, "has" },
        .{ 3, .word, "comment" },
        .{ 4, .source_comment, "//" },
        .{ 4, .enable_lint, "zlinter-enable" },
        .{ 4, .word, "rule_1" },
        .{ 4, .word, "rule_2" },
        .{ 5, .source_comment, "//" },
        .{ 5, .enable_lint, "zlinter-enable" },
        .{ 5, .word, "rule_1" },
        .{ 5, .word, "rule_2" },
        .{ 5, .word, "-" },
        .{ 5, .word, "has" },
        .{ 5, .word, "comment" },
    });
}

test "tokenize disable line comments" {
    try testTokenize(&.{
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
    try testTokenize(&.{
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
    try testTokenize(&.{
        "//! TODO: something a ",
        "/// todo something b",
        "// Todo something c",
        "// Todo(inner word) something d",
        "/// TODO(inner): something e",
        "/// TODO(): something f",
    }, &.{
        .{ 0, .file_comment, "//!" },
        .{ 0, .todo, "TODO" },
        .{ 0, .colon, ":" },
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
        .{ 3, .source_comment, "//" },
        .{ 3, .todo, "Todo" },
        .{ 3, .open_parenthesis, "(" },
        .{ 3, .word, "inner" },
        .{ 3, .word, "word" },
        .{ 3, .close_parenthesis, ")" },
        .{ 3, .word, "something" },
        .{ 3, .word, "d" },
        .{ 4, .doc_comment, "///" },
        .{ 4, .todo, "TODO" },
        .{ 4, .open_parenthesis, "(" },
        .{ 4, .word, "inner" },
        .{ 4, .close_parenthesis, ")" },
        .{ 4, .colon, ":" },
        .{ 4, .word, "something" },
        .{ 4, .word, "e" },
        .{ 5, .doc_comment, "///" },
        .{ 5, .todo, "TODO" },
        .{ 5, .open_parenthesis, "(" },
        .{ 5, .close_parenthesis, ")" },
        .{ 5, .colon, ":" },
        .{ 5, .word, "something" },
        .{ 5, .word, "f" },
    });
}

fn testTokenize(
    comptime lines: []const []const u8,
    expected: []const struct { u32, Token.Tag, []const u8 },
) !void {
    inline for (&.{ "\n", "\r\n" }) |new_line| {
        comptime var source: [:0]const u8 = "";
        if (lines.len > 0) source = source ++ lines[0];
        if (lines.len > 1) {
            inline for (lines[1..]) |line|
                source = source ++ new_line ++ line;
        }

        const tokens, const line_starts = try allocTokenize(source, std.testing.allocator);
        defer std.testing.allocator.free(line_starts);
        defer std.testing.allocator.free(tokens);

        var actual = shims.ArrayList(struct { u32, Token.Tag, []const u8 }).empty;
        defer actual.deinit(std.testing.allocator);
        for (tokens) |token| try actual.append(std.testing.allocator, .{
            token.line,
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

pub const CommentsDocument = struct {
    tokens: []const Token,
    /// Zero index inclusive
    line_starts: []const usize,
    comments: []const Comment,

    pub fn deinit(self: *CommentsDocument, allocator: std.mem.Allocator) void {
        allocator.free(self.comments);
        allocator.free(self.tokens);
        allocator.free(self.line_starts);
        self.* = undefined;
    }

    /// Returns the line number (zero-indexed) of a given byte offset from in
    /// the source of the document.
    pub fn lineNumber(self: CommentsDocument, byte_offset: usize) usize {
        for (self.line_starts[1..], 1..) |line_start, i| {
            if (byte_offset < line_start) return i - 1;
        }
        return self.line_starts.len - 1;
    }

    // TODO: Add unit tests for this new method:
    // Returns the slice containing the text content of the comment. For example
    // for a todo, this would be all text after the todo keyword.
    pub fn getCommentContent(self: @This(), comment: Comment, source: []const u8) []const u8 {
        return switch (comment.kind) {
            .line => |line| if (line.content) |c|
                source[self.tokens[c.first].first_byte .. self.tokens[c.last].first_byte + self.tokens[c.last].len]
            else
                "",
            .todo => |todo| if (todo.content) |c|
                source[self.tokens[c.first].first_byte .. self.tokens[c.last].first_byte + self.tokens[c.last].len]
            else
                "",
            .disable_lint_lines,
            .disable_lint,
            .enable_lint,
            => source[self.tokens[comment.first_token + 1].first_byte .. self.tokens[comment.last_token].first_byte + self.tokens[comment.last_token].len],
        };
    }

    pub fn getRangeContent(self: @This(), range: Comment.Range, source: []const u8) []const u8 {
        return source[self.tokens[range.first].first_byte .. self.tokens[range.last].first_byte + self.tokens[range.last].len];
    }

    pub fn debugPrint(self: CommentsDocument, file_path: []const u8, source: []const u8) void {
        for (self.comments) |comment| {
            switch (comment.kind) {
                .todo => |todo| {
                    std.debug.print("TODO: '{s}'\n", .{
                        if (todo.content) |content|
                            source[self.tokens[content.first].first_byte .. self.tokens[content.last].first_byte + self.tokens[content.last].len]
                        else
                            "",
                    });
                },
                .disable_lint_lines => |disable| {
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
    /// Inclusive - either `.doc_comment`, `.file_comment` or `.source_comment`
    first_token: Token.Index,
    /// Inclusive
    last_token: Token.Index,
    kind: Kind,

    const Range = struct {
        /// Inclusive
        first: Token.Index,
        /// Inclusive
        last: Token.Index,
    };

    const RuleIds = struct {
        /// Inclusive
        first: Token.Index,
        /// Inclusive
        last: Token.Index,
    };

    const Kind = union(enum) {
        /// Represents a comment that disables some lint rules within a line range
        /// of a given source file.
        disable_lint_lines: struct {
            /// Line of source (index zero) to disable rules from (inclusive).
            line_start: usize,

            /// Line of source (index zero) to disable rules to (inclusive).
            line_end: usize,

            /// Rules to disable, if empty, it means, disable all rules.
            rule_ids: ?RuleIds = null,
        },

        /// Represents a comment that disables some lint rules from a start line
        /// of a given source file.
        disable_lint: struct {
            /// Line of source (index zero) to disable rules from (inclusive).
            line_start: usize,

            /// Rules to disable, if empty, it means, disable all rules.
            rule_ids: ?RuleIds = null,
        },

        /// Represents a comment that enables some lint rules from a start line
        /// of a given source file (usually following a disable comment)
        enable_lint: struct {
            /// Line of source (index zero) to enable rules from (inclusive).
            line_start: usize,

            /// Rules to enable, if empty, it means, enable all rules.
            rule_ids: ?RuleIds = null,
        },

        /// Represents a `// <content>` comment in the source tree
        line: struct {
            content: ?Range = null,
        },

        /// Represents a `// TODO: <content>` comment in the source tree
        todo: struct {
            /// Optional content that appears inside the todo
            /// For example, `// todo(content here) ...`
            inner_content: ?Range = null,

            /// Optional content that appears after the todo token
            content: ?Range = null,
        },
    };

    fn debugPrint(self: Comment) void {
        std.debug.print(".{{\n", .{});
        std.debug.print("  .first_token = {d},\n", .{self.first_token});
        std.debug.print("  .last_token = {d},\n", .{self.last_token});
        std.debug.print("  .kind = .{{\n", .{});
        switch (self.kind) {
            .disable_lint_lines => |disable| {
                std.debug.print("  .disable_lint_lines = .{{\n", .{});
                std.debug.print("      .line_start = {d},\n", .{disable.line_start});
                std.debug.print("      .line_end = {d},\n", .{disable.line_end});
                if (disable.rule_ids) |rule_ids| {
                    std.debug.print("      .rule_ids = .{{\n", .{});
                    std.debug.print("        .first = {d},\n", .{rule_ids.first});
                    std.debug.print("        .last = {d},\n", .{rule_ids.last});
                    std.debug.print("      }},\n", .{});
                }
                std.debug.print("  }},\n", .{});
            },
            .disable_lint => |disable| {
                std.debug.print("  .disable_lint = .{{\n", .{});
                std.debug.print("      .line_start = {d},\n", .{disable.line_start});
                if (disable.rule_ids) |rule_ids| {
                    std.debug.print("      .rule_ids = .{{\n", .{});
                    std.debug.print("        .first = {d},\n", .{rule_ids.first});
                    std.debug.print("        .last = {d},\n", .{rule_ids.last});
                    std.debug.print("      }},\n", .{});
                }
                std.debug.print("  }},\n", .{});
            },
            .enable_lint => |enable| {
                std.debug.print("  .enable_lint = .{{\n", .{});
                std.debug.print("      .line_start = {d},\n", .{enable.line_start});
                if (enable.rule_ids) |rule_ids| {
                    std.debug.print("      .rule_ids = .{{\n", .{});
                    std.debug.print("        .first = {d},\n", .{rule_ids.first});
                    std.debug.print("        .last = {d},\n", .{rule_ids.last});
                    std.debug.print("      }},\n", .{});
                }
                std.debug.print("  }},\n", .{});
            },
            .todo => |todo| {
                std.debug.print("  .todo = .{{\n", .{});
                if (todo.inner_content) |inner_content| {
                    std.debug.print("      .inner_content = .{{\n", .{});
                    std.debug.print("        .first = {d},\n", .{inner_content.first});
                    std.debug.print("        .last = {d},\n", .{inner_content.last});
                    std.debug.print("      }},\n", .{});
                }
                if (todo.content) |content| {
                    std.debug.print("      .content = .{{\n", .{});
                    std.debug.print("        .first = {d},\n", .{content.first});
                    std.debug.print("        .last = {d},\n", .{content.last});
                    std.debug.print("      }},\n", .{});
                }
                std.debug.print("  }},\n", .{});
            },
            .line => |line| {
                std.debug.print("  .line = .{{\n", .{});
                if (line.content) |content| {
                    std.debug.print("      .content = .{{\n", .{});
                    std.debug.print("        .first = {d},\n", .{content.first});
                    std.debug.print("        .last = {d},\n", .{content.last});
                    std.debug.print("      }},\n", .{});
                }
                std.debug.print("  }},\n", .{});
            },
        }
        std.debug.print("  }},\n", .{});
        std.debug.print("}},\n", .{});
    }
};

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

pub fn allocParse(source: [:0]const u8, gpa: std.mem.Allocator) error{OutOfMemory}!CommentsDocument {
    const tokens, const line_starts = try allocTokenize(source, gpa);

    var comments = shims.ArrayList(Comment).empty;
    defer comments.deinit(gpa);

    var enables = shims.ArrayList(struct { u32, []const u8 }).empty;
    defer enables.deinit(gpa);

    var disables = shims.ArrayList(struct { u32, []const u8 }).empty;
    defer disables.deinit(gpa);

    var p = Parser{ .tokens = tokens };
    tokens: while (p.next()) |token| {
        if (!p.tokens[token].tag.isComment()) continue :tokens;
        const first_token = token;

        const kind: Comment.Kind = kind: {
            if (p.next()) |second_token| {
                switch (p.tokens[second_token].tag) {
                    .enable_lint,
                    .disable_lint,
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
                                .colon => {
                                    // TODO: Maybe one day report this mistake to user, for now lets just ignore it and keeping parsing
                                    // const slice = p.tokens[next].getSlice(source);
                                    // std.log.warn("Unexpected delimitor '{s}'. Expected a rule name", .{slice});
                                },
                                else => break,
                            }
                            p.skip();
                        }

                        break :kind switch (p.tokens[second_token].tag) {
                            .enable_lint => .{
                                .enable_lint = .{
                                    .line_start = p.tokens[second_token].line,
                                    .rule_ids = if (maybe_first_rule_token) |first_rule_token| .{
                                        .first = first_rule_token,
                                        .last = maybe_last_rule_token.?,
                                    } else null,
                                },
                            },
                            .disable_lint => .{
                                .disable_lint = .{
                                    .line_start = p.tokens[second_token].line,
                                    .rule_ids = if (maybe_first_rule_token) |first_rule_token| .{
                                        .first = first_rule_token,
                                        .last = maybe_last_rule_token.?,
                                    } else null,
                                },
                            },
                            .disable_lint_current_line => .{
                                .disable_lint_lines = .{
                                    .line_start = p.tokens[second_token].line,
                                    .line_end = p.tokens[second_token].line,
                                    .rule_ids = if (maybe_first_rule_token) |first_rule_token| .{
                                        .first = first_rule_token,
                                        .last = maybe_last_rule_token.?,
                                    } else null,
                                },
                            },
                            .disable_lint_next_line => .{
                                .disable_lint_lines = .{
                                    .line_start = p.tokens[second_token].line + 1,
                                    .line_end = p.tokens[second_token].line + 1,
                                    .rule_ids = if (maybe_first_rule_token) |first_rule_token| .{
                                        .first = first_rule_token,
                                        .last = maybe_last_rule_token.?,
                                    } else null,
                                },
                            },
                            else => unreachable,
                        };
                    },
                    .todo => {
                        const inner_content: ?Comment.Range = consume_inner_content: {
                            const next = p.peek() orelse break :consume_inner_content null;
                            if (p.tokens[next].tag != .open_parenthesis) break :consume_inner_content null;
                            p.skip();

                            var maybe_first: ?Token.Index = null;
                            var maybe_last: ?Token.Index = null;
                            while (p.peek()) |token_index| {
                                if (p.tokens[token_index].tag == .close_parenthesis) break;
                                maybe_first = maybe_first orelse token_index;
                                maybe_last = token_index;

                                p.skip();
                            }

                            const first = maybe_first orelse break :consume_inner_content null;
                            const last = maybe_last orelse break :consume_inner_content null;

                            break :consume_inner_content .{
                                .first = first,
                                .last = last,
                            };
                        };

                        // Skip colon if present:
                        while (p.peek()) |peek| {
                            if (p.tokens[peek].tag != .colon) break;
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

                        break :kind .{
                            .todo = .{
                                .content = if (maybe_last_token) |last_token_index| .{
                                    .first = first_content_token_index,
                                    .last = last_token_index,
                                } else null,
                                .inner_content = inner_content,
                            },
                        };
                    },
                    else => {
                        p.i -= 1; // unwind to consume first token after `//`, `///`, or `//!`
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

                        break :kind .{
                            .line = .{
                                .content = if (maybe_last_token) |last_token_index| .{
                                    .first = first_content_token_index,
                                    .last = last_token_index,
                                } else null,
                            },
                        };
                    },
                }
            } else break :kind .{
                // No token after start of comment token so empty line
                .line = .{
                    .content = null,
                },
            };
        };

        // Skip until we see another comment tag or EOF
        while (p.peek()) |index| {
            if (p.tokens[index].tag.isComment()) break else p.i += 1;
        }

        try comments.append(gpa, .{
            .first_token = first_token,
            .last_token = p.i - 1,
            .kind = kind,
        });
    }

    return .{
        .tokens = tokens,
        .comments = try comments.toOwnedSlice(gpa),
        .line_starts = line_starts,
    };
}

test "parse - no comments" {
    try testParse(&.{""}, &.{});
    try testParse(&.{}, &.{});
    try testParse(&.{"var ok = 1;"}, &.{});
}

test "parse - todo comments" {
    try testParse(
        &.{
            "// TODO:  First todo ",
            "// todo  Second todo ",
            "// Todo", // Deliberately empty
            "// TODO(#10)",
            "// TODO(hello world) message",
            "// TODO(): message",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 4,
                .kind = .{
                    .todo = .{
                        .content = .{
                            .first = 3,
                            .last = 4,
                        },
                    },
                },
            },
            .{
                .first_token = 5,
                .last_token = 8,
                .kind = .{
                    .todo = .{
                        .content = .{
                            .first = 7,
                            .last = 8,
                        },
                    },
                },
            },
            .{
                .first_token = 9,
                .last_token = 10,
                .kind = .{
                    .todo = .{},
                },
            },
            .{
                .first_token = 11,
                .last_token = 15,
                .kind = .{
                    .todo = .{
                        .inner_content = .{
                            .first = 14,
                            .last = 14,
                        },
                        .content = .{
                            .first = 15,
                            .last = 15,
                        },
                    },
                },
            },
            .{
                .first_token = 16,
                .last_token = 22,
                .kind = .{
                    .todo = .{
                        .inner_content = .{
                            .first = 19,
                            .last = 20,
                        },
                        .content = .{
                            .first = 21,
                            .last = 22,
                        },
                    },
                },
            },
            .{
                .first_token = 23,
                .last_token = 28,
                .kind = .{
                    .todo = .{
                        .content = .{
                            .first = 26,
                            .last = 28,
                        },
                    },
                },
            },
        },
    );
}

test "parse - line comments" {
    try testParse(&.{
        "//! Hello from file comment",
        "// Hello from a line ",
        "/// ", // Deliberately empty
    }, &.{
        .{
            .first_token = 0,
            .last_token = 4,
            .kind = .{
                .line = .{
                    .content = .{
                        .first = 1,
                        .last = 4,
                    },
                },
            },
        },
        .{
            .first_token = 5,
            .last_token = 9,
            .kind = .{
                .line = .{
                    .content = .{
                        .first = 6,
                        .last = 9,
                    },
                },
            },
        },
        .{
            .first_token = 10,
            .last_token = 10,
            .kind = .{
                .line = .{},
            },
        },
    });
}

test "parse - disable next line comments" {
    try testParse(
        &.{
            "// zlinter-disable-next-line rule_a - false positive",
            "var unused = 1;",
        },
        &.{.{
            .first_token = 0,
            .last_token = 5,
            .kind = .{
                .disable_lint_lines = .{
                    .line_start = 1,
                    .line_end = 1,
                    .rule_ids = .{
                        .first = 2,
                        .last = 2,
                    },
                },
            },
        }},
    );

    try testParse(
        &.{
            "",
            "",
            "// zlinter-disable-next-line rule_a rule_b",
            "var unused = 1;",
        },
        &.{.{
            .first_token = 0,
            .last_token = 3,
            .kind = .{
                .disable_lint_lines = .{
                    .line_start = 3,
                    .line_end = 3,
                    .rule_ids = .{
                        .first = 2,
                        .last = 3,
                    },
                },
            },
        }},
    );

    try testParse(
        &.{
            "",
            "// zlinter-disable-next-line",
            "var unused = 1;",
        },
        &.{.{
            .first_token = 0,
            .last_token = 1,
            .kind = .{
                .disable_lint_lines = .{
                    .line_start = 2,
                    .line_end = 2,
                },
            },
        }},
    );
}

test "parse - disable current line comments" {
    try testParse(
        &.{
            "var unused = 1; // zlinter-disable-current-line rule_a - false positive",
        },
        &.{.{
            .first_token = 0,
            .last_token = 5,
            .kind = .{
                .disable_lint_lines = .{
                    .line_start = 0,
                    .line_end = 0,
                    .rule_ids = .{
                        .first = 2,
                        .last = 2,
                    },
                },
            },
        }},
    );

    try testParse(
        &.{
            "",
            "",
            "var unused = 1; // zlinter-disable-current-line rule_a rule_b",
        },
        &.{.{
            .first_token = 0,
            .last_token = 3,
            .kind = .{
                .disable_lint_lines = .{
                    .line_start = 2,
                    .line_end = 2,
                    .rule_ids = .{
                        .first = 2,
                        .last = 3,
                    },
                },
            },
        }},
    );

    try testParse(
        &.{
            "",
            "var unused = 1; // zlinter-disable-current-line",
        },
        &.{.{
            .first_token = 0,
            .last_token = 1,
            .kind = .{
                .disable_lint_lines = .{
                    .line_start = 1,
                    .line_end = 1,
                },
            },
        }},
    );
}

test "parse - disable" {
    try testParse(
        &.{
            "",
            "// zlinter-disable rule_a - false positive",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 5,
                .kind = .{
                    .disable_lint = .{
                        .line_start = 1,
                        .rule_ids = .{ .first = 2, .last = 2 },
                    },
                },
            },
        },
    );

    try testParse(
        &.{
            "",
            "",
            "// zlinter-disable rule_a rule_b",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 3,
                .kind = .{
                    .disable_lint = .{
                        .line_start = 2,
                        .rule_ids = .{ .first = 2, .last = 3 },
                    },
                },
            },
        },
    );

    try testParse(
        &.{
            "",
            "// zlinter-disable",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 1,
                .kind = .{
                    .disable_lint = .{ .line_start = 1 },
                },
            },
        },
    );
}

test "parse - enable" {
    try testParse(
        &.{
            "",
            "// zlinter-enable rule_a - false positive",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 5,
                .kind = .{
                    .enable_lint = .{
                        .line_start = 1,
                        .rule_ids = .{ .first = 2, .last = 2 },
                    },
                },
            },
        },
    );

    try testParse(
        &.{
            "",
            "",
            "// zlinter-enable rule_a rule_b",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 3,
                .kind = .{
                    .enable_lint = .{
                        .line_start = 2,
                        .rule_ids = .{ .first = 2, .last = 3 },
                    },
                },
            },
        },
    );

    try testParse(
        &.{
            "",
            "// zlinter-enable",
        },
        &.{
            .{
                .first_token = 0,
                .last_token = 1,
                .kind = .{
                    .enable_lint = .{ .line_start = 1 },
                },
            },
        },
    );
}

test "lineNumber" {
    var doc_comments = try allocParse(
        \\123
        \\4
        \\56
    , std.testing.allocator);
    defer doc_comments.deinit(std.testing.allocator);

    try std.testing.expectEqual(0, doc_comments.lineNumber(0)); // 1
    try std.testing.expectEqual(0, doc_comments.lineNumber(1)); // 2
    try std.testing.expectEqual(0, doc_comments.lineNumber(2)); // 3
    try std.testing.expectEqual(0, doc_comments.lineNumber(3)); // \n
    try std.testing.expectEqual(1, doc_comments.lineNumber(4)); // 4
    try std.testing.expectEqual(1, doc_comments.lineNumber(5)); // \n
    try std.testing.expectEqual(2, doc_comments.lineNumber(6)); // 5
    try std.testing.expectEqual(2, doc_comments.lineNumber(7)); // 6

    // Maybe one day this should become an assertion but for now assumes anything
    // past the last line is on the last line...
    try std.testing.expectEqual(2, doc_comments.lineNumber(100));
}

fn testParse(
    comptime lines: []const []const u8,
    expected: []const Comment,
) !void {
    inline for (&.{ "\n", "\r\n" }) |new_line| {
        comptime var source: [:0]const u8 = "";
        if (lines.len > 0) source = source ++ lines[0];
        if (lines.len > 1) {
            inline for (lines[1..]) |line|
                source = source ++ new_line ++ line;
        }

        var doc_comments = try allocParse(source, std.testing.allocator);
        defer doc_comments.deinit(std.testing.allocator);

        const actual = doc_comments.comments;
        std.testing.expectEqualDeep(expected, actual) catch |e| {
            std.debug.print("Expected: &.{{\n", .{});
            for (expected) |comment| comment.debugPrint();
            std.debug.print("}}\n", .{});

            std.debug.print("Actual: &.{{\n", .{});
            for (actual) |comment| comment.debugPrint();
            std.debug.print("}}\n", .{});
            return e;
        };
    }
}

pub const LazyRuleSkipper = struct {
    const Index = struct {
        /// Bits are set for enabled lines
        all: std.bit_set.DynamicBitSet,
        /// Bits are set for enabled lines per rule
        rules: std.StringHashMap(std.bit_set.DynamicBitSet),

        fn deinit(self: *@This()) void {
            self.all.deinit();
            var it = self.rules.iterator();
            while (it.next()) |e| e.value_ptr.deinit();
            self.rules.deinit();
        }
    };

    index: ?Index = null,
    doc: CommentsDocument,
    gpa: std.mem.Allocator,
    source: []const u8,

    pub fn init(doc: CommentsDocument, source: []const u8, gpa: std.mem.Allocator) LazyRuleSkipper {
        return .{
            .doc = doc,
            .source = source,
            .gpa = gpa,
        };
    }

    pub fn deinit(self: *LazyRuleSkipper) void {
        if (self.index) |*index| index.deinit();
    }

    pub fn shouldSkip(self: *LazyRuleSkipper, problem: LintProblem) error{OutOfMemory}!bool {
        const index = try self.ensureBuilt();

        const line = self.doc.lineNumber(problem.start.byte_offset);
        if (!index.all.isSet(line)) return true;

        if (index.rules.get(problem.rule_id)) |bits|
            if (!bits.isSet(line)) return true;

        return false;
    }

    fn ensureBuilt(self: *LazyRuleSkipper) error{OutOfMemory}!Index {
        if (self.index) |index| return index;

        const line_count = self.doc.line_starts.len;
        var index: Index = .{
            .rules = .init(self.gpa),
            .all = try .initFull(self.gpa, line_count + 1),
        };
        errdefer index.deinit();

        for (self.doc.comments) |comment| {
            const set: struct { range: std.bit_set.Range, rule_ids: ?Comment.RuleIds, value: bool } = switch (comment.kind) {
                .disable_lint_lines => |info| .{
                    .range = .{
                        .start = info.line_start,
                        .end = info.line_end + 1, // + 1 as not inclusive but line_end is
                    },
                    .rule_ids = info.rule_ids,
                    .value = false,
                },
                .disable_lint => |info| .{
                    .range = .{ .start = info.line_start, .end = line_count },
                    .rule_ids = info.rule_ids,
                    .value = false,
                },
                .enable_lint => |info| .{
                    .range = .{ .start = info.line_start, .end = line_count },
                    .rule_ids = info.rule_ids,
                    .value = true,
                },
                else => continue,
            };
            if (set.rule_ids) |rule_ids| {
                for (self.doc.tokens[rule_ids.first .. rule_ids.last + 1]) |token| {
                    const rule_id = self.source[token.first_byte .. token.first_byte + token.len];

                    const result = try index.rules.getOrPut(rule_id);
                    if (!result.found_existing) {
                        result.value_ptr.* = try .initFull(self.gpa, line_count + 1);
                    }
                    result.value_ptr.setRangeValue(set.range, set.value);
                }
            } else {
                index.all.setRangeValue(set.range, set.value);
            }
        }
        self.index = index;
        return index;
    }
};

const std = @import("std");
const LintProblem = @import("results.zig").LintProblem;
const shims = @import("shims.zig");
