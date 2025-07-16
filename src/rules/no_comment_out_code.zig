//! Enforces that there's no source code comments that look like code.
//!
//! Code encased in backticks, like `this` is ignored.

/// Config for no_comment_out_code rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_comment_out_code rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_comment_out_code),
        .run = &run,
    };
}

/// Runs the no_comment_out_code rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    var content_accumulator = std.ArrayList(u8).init(allocator);
    defer content_accumulator.deinit();

    var first_comment: ?zlinter.comments.Comment = null;
    var last_comment: ?zlinter.comments.Comment = null;

    var prev_line: u32 = 0;

    for (doc.comments.comments) |comment| {
        if (comment.kind != .line) continue;
        const contents = doc.comments.getCommentContent(comment, doc.handle.tree.source);
        const line = doc.comments.tokens[comment.first_token].line;
        defer prev_line = line;

        if (content_accumulator.items.len == 0 or prev_line == line - 1) {
            if (content_accumulator.items.len == 0) {
                try content_accumulator.appendSlice("fn container() void {");
            }
            try content_accumulator.appendSlice(contents);
            try content_accumulator.append('\n');
        } else {
            if (content_accumulator.items.len > 0) {
                if (try looksLikeCode(content_accumulator.items[0..], allocator)) {
                    try lint_problems.append(.{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfComment(doc.comments, first_comment.?),
                        .end = .endOfComment(doc.comments, last_comment.?),
                        .message = try allocator.dupe(u8, "Avoid code in comments"),
                    });
                }

                content_accumulator.clearAndFree();
                first_comment = null;
                last_comment = null;
            }
            try content_accumulator.appendSlice(contents);
            try content_accumulator.append('\n');
        }

        first_comment = first_comment orelse comment;
        last_comment = comment;
    }

    if (content_accumulator.items.len > 0) {
        if (try looksLikeCode(content_accumulator.items[0..], allocator)) {
            try lint_problems.append(.{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfComment(doc.comments, first_comment.?),
                .end = .endOfComment(doc.comments, last_comment.?),
                .message = try allocator.dupe(u8, "Avoid code in comments"),
            });
        }

        content_accumulator.clearAndFree();
        first_comment = null;
        last_comment = null;
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(),
        )
    else
        null;
}

fn looksLikeCode(content: []const u8, gpa: std.mem.Allocator) !bool {
    if (content.len == 0) return false;
    if (std.mem.containsAtLeastScalar(u8, content, 1, '`')) return false;

    const statement_container_fmt = "fn wrap() void {{\n{s}\n}}\n";
    const declaration_container_fmt = "{s}";

    const buffer = try gpa.allocSentinel(u8, content.len + @max(statement_container_fmt.len, declaration_container_fmt.len) + 1, 0);
    defer gpa.free(buffer);

    const looks_like_statement = looks_like_statement: {
        const container_code = std.fmt.bufPrintZ(buffer, statement_container_fmt, .{content}) catch unreachable;
        var ast = try std.zig.Ast.parse(gpa, container_code, .zig);
        defer ast.deinit(gpa);

        const root_and_wrap_fn_nodes = 5;
        if (ast.nodes.len <= root_and_wrap_fn_nodes) break :looks_like_statement false;
        if (ast.errors.len > 0) break :looks_like_statement false;
        break :looks_like_statement true;
    };
    if (looks_like_statement) return true;

    const looks_like_declaration = looks_like_declaration: {
        const root_code = std.fmt.bufPrintZ(buffer, declaration_container_fmt, .{content}) catch unreachable;
        var ast = try std.zig.Ast.parse(gpa, root_code, .zig);
        defer ast.deinit(gpa);

        // zlinter-disable-next-line no_comment_out_code
        // var dummy_node: u32 = 0;
        // while (dummy_node < ast.nodes.len) : (dummy_node += 1) {
        //     std.debug.print("{s} = '{s}'\n", .{ @tagName(zlinter.shims.nodeTag(ast, dummy_node)), ast.getNodeSource(dummy_node) });
        // }

        const root_node = 1;
        if (ast.nodes.len <= root_node) break :looks_like_declaration false;
        if (ast.errors.len > 0) break :looks_like_declaration false;

        var node = zlinter.shims.NodeIndexShim.init(0);
        while (node.index < ast.nodes.len) : (node.index += 1) {
            switch (zlinter.shims.nodeTag(ast, node.toNodeIndex())) {
                .test_decl,
                .global_var_decl,
                .local_var_decl,
                .simple_var_decl,
                .aligned_var_decl,
                .fn_decl,
                .container_field_align,
                .container_field,
                => break :looks_like_declaration true,
                else => {
                    // TODO: Work out the container field situation as the AST
                    // appears to not be behaving how it is documented.
                    // zlinter-disable-next-line no_comment_out_code
                    // if (ast.fullContainerField(node.toNodeIndex())) |container_field| {
                    //     std.debug.print("{} - '{s}'\n", .{ container_field.ast, ast.tokenSlice(container_field.ast.main_token) });
                    //     if (zlinter.shims.NodeIndexShim.initOptional(container_field.ast.type_expr) != null and
                    //         ast.lastToken(node.toNodeIndex()) + 1 < ast.tokens.len and
                    //         ast.tokens.items(.tag)[ast.lastToken(node.toNodeIndex()) + 1] == .comma)
                    //     {
                    //         break :looks_like_declaration true;
                    //     }
                    // }
                },
            }
        }
        break :looks_like_declaration false;
    };
    return looks_like_declaration;

    // zlinter-disable-next-line no_comment_out_code
    // const looks_like_code = looks_like_code: {
    //     var node = zlinter.shims.NodeIndexShim.init(0);
    //     while (node.index < ast.nodes.len) : (node.index += 1) {
    //         // std.debug.print(" - {s}\n", .{@tagName(zlinter.shims.nodeTag(ast, node.toNodeIndex()))});
    //         switch (zlinter.shims.nodeTag(ast, node.toNodeIndex())) {
    //             .test_decl,
    //             .global_var_decl,
    //             .local_var_decl,
    //             .simple_var_decl,
    //             .aligned_var_decl,
    //             .@"errdefer",
    //             .@"defer",
    //             .assign_mul,
    //             .assign_div,
    //             .assign_mod,
    //             .assign_add,
    //             .assign_sub,
    //             .assign_shl,
    //             .assign_shl_sat,
    //             .assign_shr,
    //             .assign_bit_and,
    //             .assign_bit_xor,
    //             .assign_bit_or,
    //             .assign_mul_wrap,
    //             .assign_add_wrap,
    //             .assign_sub_wrap,
    //             .assign_mul_sat,
    //             .assign_add_sat,
    //             .assign_sub_sat,
    //             .assign,
    //             .assign_destructure,
    //             .call_one,
    //             .call_one_comma,
    //             .call,
    //             .call_comma,
    //             .@"switch",
    //             .switch_comma,
    //             .while_simple,
    //             .while_cont,
    //             .@"while",
    //             .for_simple,
    //             .@"for",
    //             .for_range,
    //             .if_simple,
    //             .@"if",
    //             .@"continue",
    //             .@"break",
    //             .@"return",
    //             .fn_proto_simple,
    //             .fn_proto_multi,
    //             .fn_proto_one,
    //             .fn_proto,
    //             .fn_decl,
    //             .builtin_call_two,
    //             .builtin_call_two_comma,
    //             .builtin_call,
    //             .builtin_call_comma,
    //             .error_set_decl,
    //             .container_decl,
    //             .container_decl_trailing,
    //             .container_decl_two,
    //             .container_decl_two_trailing,
    //             .container_decl_arg,
    //             .container_decl_arg_trailing,
    //             .tagged_union,
    //             .tagged_union_trailing,
    //             .tagged_union_two,
    //             .tagged_union_two_trailing,
    //             .tagged_union_enum_tag,
    //             .tagged_union_enum_tag_trailing,
    //             => break :looks_like_code true,
    //             else => {},
    //         }
    //     }
    //     break :looks_like_code false;
    // };
    //
    // return looks_like_code;
}

test "looksLikeCode when true" {
    inline for (&.{
        "var a: u32 = 10;",
        \\std.debug.print("Hello world", .{});
        ,
        \\ const a = @import("b");
        ,
        \\ pub fn example() u32 {
        \\  return 10; 
        \\}
        // ,
        // \\ field: u32,
        // ,
        // \\ field: u32 = 1,
    }) |content| {
        std.testing.expect(try looksLikeCode(content, std.testing.allocator)) catch |e| {
            std.debug.print("Expected is code: '{s}'\n", .{content});
            return e;
        };
    }
}

test "looksLikeCode when false" {
    inline for (&.{
        "e.g., `var a: u32 = 10;`",
        \\e.g., `std.debug.print("Hello world", .{});`
        ,
        "a",
        "var",
        "const",
        "this is a single line comment",
        \\ field,
        ,
        \\ field = 1,
    }) |content| {
        std.testing.expect(!(try looksLikeCode(content, std.testing.allocator))) catch |e| {
            std.debug.print("Expected not code: '{s}'\n", .{content});
            return e;
        };
    }
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
