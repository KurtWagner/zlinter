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
        for (self.problems) |err| {
            allocator.free(err.message);
        }
        allocator.free(self.problems);
        allocator.free(self.file_path);
    }
};

pub const LintProblemLocation = struct {
    /// Location in entire source (inclusive)
    byte_offset: usize,
    /// Line number in source (index zero)
    line: usize,
    /// Column on line in source (index zero)
    column: usize,

    pub const zero: LintProblemLocation = .{
        .byte_offset = 0,
        .line = 0,
        .column = 0,
    };

    pub fn startOfNode(tree: std.zig.Ast, index: std.zig.Ast.Node.Index) LintProblemLocation {
        const first_token_loc = tree.tokenLocation(0, tree.firstToken(index));
        return .{
            .byte_offset = first_token_loc.line_start + first_token_loc.column,
            .line = first_token_loc.line,
            .column = first_token_loc.column,
        };
    }

    test startOfNode {
        var ast = try std.zig.Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer ast.deinit(std.testing.allocator);

        const a_decl = ast.rootDecls()[0];
        const b_decl = ast.rootDecls()[1];

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 0,
            .line = 0,
            .column = 0,
        }, LintProblemLocation.startOfNode(ast, a_decl));

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 17,
            .line = 1,
            .column = 0,
        }, LintProblemLocation.startOfNode(ast, b_decl));
    }

    pub fn endOfNode(tree: std.zig.Ast, index: std.zig.Ast.Node.Index) LintProblemLocation {
        const last_token = tree.lastToken(index);
        const last_token_loc = tree.tokenLocation(0, last_token);
        const column = last_token_loc.column + tree.tokenSlice(last_token).len;
        return .{
            .byte_offset = last_token_loc.line_start + column,
            .line = last_token_loc.line,
            .column = column,
        };
    }

    test endOfNode {
        var ast = try std.zig.Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer ast.deinit(std.testing.allocator);

        const a_decl = ast.rootDecls()[0];
        const b_decl = ast.rootDecls()[1];

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 15,
            .line = 0,
            .column = 15,
        }, LintProblemLocation.endOfNode(ast, a_decl));

        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 32,
            .line = 1,
            .column = 15,
        }, LintProblemLocation.endOfNode(ast, b_decl));
    }

    pub fn startOfToken(tree: std.zig.Ast, index: std.zig.Ast.TokenIndex) LintProblemLocation {
        const loc = tree.tokenLocation(0, index);
        return .{
            .byte_offset = loc.line_start + loc.column,
            .line = loc.line,
            .column = loc.column,
        };
    }

    test startOfToken {
        var ast = try std.zig.Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer ast.deinit(std.testing.allocator);

        // `pub` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 0,
            .line = 0,
            .column = 0,
        }, LintProblemLocation.startOfToken(ast, 0));

        // `const` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 4,
            .line = 0,
            .column = 4,
        }, LintProblemLocation.startOfToken(ast, 1));

        // `pub` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 17,
            .line = 1,
            .column = 0,
        }, LintProblemLocation.startOfToken(ast, 6));

        // `const` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 21,
            .line = 1,
            .column = 4,
        }, LintProblemLocation.startOfToken(ast, 7));
    }

    pub fn endOfToken(tree: std.zig.Ast, index: std.zig.Ast.TokenIndex) LintProblemLocation {
        const loc = tree.tokenLocation(0, index);
        const column = loc.column + tree.tokenSlice(index).len - 1;
        return .{
            .byte_offset = loc.line_start + column,
            .line = loc.line,
            .column = column,
        };
    }

    test endOfToken {
        var ast = try std.zig.Ast.parse(std.testing.allocator,
            \\pub const a = 1;
            \\pub const b = 2;
        , .zig);
        defer ast.deinit(std.testing.allocator);

        // `pub` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 2,
            .line = 0,
            .column = 2,
        }, LintProblemLocation.endOfToken(ast, 0));

        // `const` on line 1
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 8,
            .line = 0,
            .column = 8,
        }, LintProblemLocation.endOfToken(ast, 1));

        // `pub` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 19,
            .line = 1,
            .column = 2,
        }, LintProblemLocation.endOfToken(ast, 6));

        // `const` on line 2
        try std.testing.expectEqualDeep(LintProblemLocation{
            .byte_offset = 25,
            .line = 1,
            .column = 8,
        }, LintProblemLocation.endOfToken(ast, 7));
    }

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = @splat(' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .byte_offset = {d},\n", .{ indent_str, self.byte_offset });
        writer.print("{s}  .line = {d},\n", .{ indent_str, self.line });
        writer.print("{s}  .column = {d},\n", .{ indent_str, self.column });
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

    pub fn sliceSource(self: Self, source: [:0]const u8) []const u8 {
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
        writer.print("  .disabled_by_comment = {?},\n", .{self.disabled_by_comment});

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
    start: usize,
    end: usize,
    text: []const u8,

    pub fn debugPrint(self: @This(), writer: anytype) void {
        self.debugPrintWithIndent(writer, 0);
    }

    fn debugPrintWithIndent(self: @This(), writer: anytype, indent: usize) void {
        var spaces: [80]u8 = @splat(' ');
        const indent_str = spaces[0..indent];

        writer.print("{s}.{{\n", .{indent_str});
        writer.print("{s}  .start = {d},\n", .{ indent_str, self.start });
        writer.print("{s}  .end = {d},\n", .{ indent_str, self.end });
        writer.print("{s}  .text = \"{s}\",\n", .{ indent_str, self.text });
        writer.print("{s}}},\n", .{indent_str});
    }
};

const std = @import("std");
const rules = @import("rules.zig");
