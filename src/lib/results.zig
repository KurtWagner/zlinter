//! Linter results

/// Result from running a lint rule.
pub const LintResult = struct {
    const Self = @This();

    file_path: []const u8,
    problems: []LintProblem,

    /// Initializes a result. Caller must call deinit once done to free memory.
    pub fn init(
        allocator: std.mem.Allocator,
        file_path: []const u8,
        problems: []LintProblem,
    ) error{OutOfMemory}!Self {
        return .{
            .file_path = try allocator.dupe(u8, file_path),
            .problems = problems,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.problems) |*err| {
            err.deinit(allocator);
        }
        allocator.free(self.problems);
        allocator.free(self.file_path);
    }
};

pub const LintProblemLocation = struct {
    /// Location in entire source (inclusive)
    byte_offset: usize,

    pub const zero: LintProblemLocation = .{
        .byte_offset = 0,
    };

    pub fn startOfNode(tree: Ast, index: Ast.Node.Index) LintProblemLocation {
        return .startOfToken(tree, tree.firstToken(index));
    }

    test startOfNode {
        var tree = try Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer tree.deinit(std.testing.allocator);

        const a_decl = tree.rootDecls()[0];
        const b_decl = tree.rootDecls()[1];

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 0,
        }, LintProblemLocation.startOfNode(tree, a_decl));

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 17,
        }, LintProblemLocation.startOfNode(tree, b_decl));
    }

    pub fn endOfNode(tree: Ast, index: Ast.Node.Index) LintProblemLocation {
        return .endOfToken(tree, tree.lastToken(index));
    }

    test endOfNode {
        var tree = try Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer tree.deinit(std.testing.allocator);

        const a_decl = tree.rootDecls()[0];
        const b_decl = tree.rootDecls()[1];

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 14,
        }, LintProblemLocation.endOfNode(tree, a_decl));

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 31,
        }, LintProblemLocation.endOfNode(tree, b_decl));
    }

    pub fn startOfToken(tree: Ast, index: Ast.TokenIndex) LintProblemLocation {
        return .{
            .byte_offset = tree.tokenStart(index),
        };
    }

    test startOfToken {
        var tree = try Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer tree.deinit(std.testing.allocator);

        // `pub` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 0,
        }, LintProblemLocation.startOfToken(tree, 0));

        // `const` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 4,
        }, LintProblemLocation.startOfToken(tree, 1));

        // `pub` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 17,
        }, LintProblemLocation.startOfToken(tree, 6));

        // `const` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 21,
        }, LintProblemLocation.startOfToken(tree, 7));
    }

    pub fn endOfToken(tree: Ast, index: Ast.TokenIndex) LintProblemLocation {
        return .{
            // Minus 1 as inclusive
            .byte_offset = tree.tokenStart(index) + tree.tokenSlice(index).len - 1,
        };
    }

    test endOfToken {
        var tree = try Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer tree.deinit(std.testing.allocator);

        // `pub` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 2,
        }, LintProblemLocation.endOfToken(tree, 0));

        // `const` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 8,
        }, LintProblemLocation.endOfToken(tree, 1));

        // `pub` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 19,
        }, LintProblemLocation.endOfToken(tree, 6));

        // `const` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 25,
        }, LintProblemLocation.endOfToken(tree, 7));
    }

    pub fn startOfComment(doc: comments.CommentsDocument, comment: comments.Comment) LintProblemLocation {
        const first_token = doc.tokens[comment.first_token];
        return .{
            .byte_offset = first_token.first_byte,
        };
    }

    test startOfComment {
        const source: [:0]const u8 =
            \\ //! Comment 1
            \\ var ok = 1; // Comment 2
            \\ /// Comment 3
        ;
        var doc = try comments.allocParse(source, std.testing.allocator);
        defer doc.deinit(std.testing.allocator);

        // For `//! Comment 1`
        try std.testing.expectEqualDeep(
            LintProblemLocation{
                .byte_offset = 1,
            },
            LintProblemLocation.startOfComment(doc, doc.comments[0]),
        );

        // For `... // Comment 2`
        try std.testing.expectEqualDeep(
            LintProblemLocation{
                .byte_offset = 28,
            },
            LintProblemLocation.startOfComment(doc, doc.comments[1]),
        );

        // For `/// Comment 3`
        try std.testing.expectEqualDeep(
            LintProblemLocation{
                .byte_offset = 42,
            },
            LintProblemLocation.startOfComment(doc, doc.comments[2]),
        );
    }

    pub fn endOfComment(doc: comments.CommentsDocument, comment: comments.Comment) LintProblemLocation {
        const last_token = doc.tokens[comment.last_token];
        return .{
            .byte_offset = last_token.first_byte + last_token.len,
        };
    }

    test endOfComment {
        const source: [:0]const u8 =
            \\ //! Comment 1
            \\ var ok = 1; // Comment 2
            \\ /// Comment 3
        ;
        var doc = try comments.allocParse(source, std.testing.allocator);
        defer doc.deinit(std.testing.allocator);

        // For `//! Comment 1`
        try std.testing.expectEqualDeep(
            LintProblemLocation{
                .byte_offset = 14,
            },
            LintProblemLocation.endOfComment(doc, doc.comments[0]),
        );

        // For `... // Comment 2`
        try std.testing.expectEqualDeep(
            LintProblemLocation{
                .byte_offset = 40,
            },
            LintProblemLocation.endOfComment(doc, doc.comments[1]),
        );

        // For `/// Comment 3`
        try std.testing.expectEqualDeep(
            LintProblemLocation{
                .byte_offset = 55,
            },
            LintProblemLocation.endOfComment(doc, doc.comments[2]),
        );
    }

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = @splat(' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .byte_offset = {d},\n", .{ indent_str, self.byte_offset });
        writer.print("{s}}},\n", .{indent_str});
    }
};

pub const LintProblem = struct {
    const Self = @This();

    rule_id: []const u8,
    severity: rules.LintProblemSeverity,
    start: LintProblemLocation,
    end: LintProblemLocation,

    message: []const u8,
    disabled_by_comment: bool = false,
    fix: ?LintProblemFix = null,

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.fix) |*fix| fix.deinit(allocator);

        self.* = undefined;
    }

    pub fn sliceSource(self: Self, source: [:0]const u8) []const u8 {
        if (self.start.byte_offset == 0 and self.start.byte_offset == self.end.byte_offset) return "";
        return source[self.start.byte_offset .. self.end.byte_offset + 1];
    }

    pub fn debugPrint(self: Self, writer: anytype) void {
        writer.print(".{{\n", .{});
        writer.print("  .rule_id = \"{s}\",\n", .{self.rule_id});
        writer.print("  .severity = .@\"{s}\",\n", .{@tagName(self.severity)});
        writer.print("  .start =\n", .{});
        self.start.debugPrintWithIndent(writer, 4);

        writer.print("  .end =\n", .{});
        self.end.debugPrintWithIndent(writer, 4);

        writer.print("  .message = \"{s}\",\n", .{self.message});
        writer.print("  .disabled_by_comment = {},\n", .{self.disabled_by_comment});

        if (self.fix) |fix| {
            writer.print("  .fix =\n", .{});
            fix.debugPrintWithIndent(writer, 4);
        } else {
            writer.print("  .fix = null,\n", .{});
        }

        writer.print("}},\n", .{});
    }
};

pub const LintProblemFix = struct {
    /// Start inclusive byte offset in document.
    start: usize,

    /// End exclusive byte offset in document.
    end: usize,

    /// Text to write between start and end (owned and freed by deinit)
    text: []const u8,

    pub fn deinit(self: *LintProblemFix, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    pub fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = @splat(' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .start = {d},\n", .{ indent_str, self.start });
        writer.print("{s}  .end = {d},\n", .{ indent_str, self.end });

        const has_quote = std.mem.indexOfScalar(u8, self.text, '"') != null;
        const has_newline = std.mem.indexOfScalar(u8, self.text, '\n') != null;

        writer.print("{s}  .text ={s}", .{ indent_str, if (has_newline) "\n" else "" });
        if (has_newline or has_quote) {
            strings.debugPrintMultilineString(self.text, writer, indent + 2);
        } else {
            writer.print("\"{s}\"", .{self.text});
        }
        writer.print("{s}{s},\n", .{ if (has_newline or has_quote) "\n" else "", indent_str });
        writer.print("{s}}},\n", .{indent_str});
    }
};

const comments = @import("comments.zig");
const rules = @import("rules.zig");
const std = @import("std");
const strings = @import("strings.zig");
const Ast = std.zig.Ast;
