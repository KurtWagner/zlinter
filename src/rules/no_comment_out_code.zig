//! Discourage leaving commented-out code in committed files.
//!
//! **Why?**
//!
//! Commenting out blocks of old or unused code might seem helpful during development, but leaving them behind creates clutter and confusion over time.
//!
//! **Problems:**
//!
//! * Makes files noisy - harder to read and navigate.
//! * Creates dead code that might be mistakenly reused or assumed to be maintained.
//! * Can increase merge conflicts and noise in diffs.
//! * Hides real version history — version control should preserve old code, not your comments!
//!
//! **What to do instead?**:
//!
//! * If you don’t need it, delete it — you can always recover it from version control.
//! * If it’s experimental, keep it on a branch or behind a flag instead.
//!
//! **Notes:**
//!
//! * Comments that contain back ticks, like `this("example")` will be ignored
//! * The heuristic of what looks like code isn't perfect and may have false
//! negatives (e.g., commenting out struct fields) but will slowly improve
//! overtime as the linter evolves.

/// Config for no_comment_out_code rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_comment_out_code rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_comment_out_code),
        .run = &run,
    };
}

/// Runs the no_comment_out_code rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems: shims.ArrayList(zlinter.results.LintProblem) = .{};
    defer lint_problems.deinit(gpa);

    var content_accumulator: shims.ArrayList(u8) = .{};
    defer content_accumulator.deinit(gpa);

    var first_comment: ?zlinter.comments.Comment = null;
    var last_comment: ?zlinter.comments.Comment = null;

    var prev_line: u32 = 0;

    for (doc.comments.comments) |comment| {
        if (comment.kind != .line) continue;
        const contents = doc.comments.getCommentContent(comment, doc.handle.tree.source);
        const line = doc.comments.tokens[comment.first_token].line;
        defer prev_line = line;

        if (content_accumulator.items.len == 0 or prev_line == line - 1) {
            try content_accumulator.appendSlice(gpa, contents);
            try content_accumulator.append(gpa, '\n');
        } else {
            if (content_accumulator.items.len > 0) {
                if (try looksLikeCode(content_accumulator.items[0..], gpa)) {
                    try lint_problems.append(gpa, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = zlinter.results.LintProblemLocation.startOfComment(doc.comments, first_comment.?),
                        .end = zlinter.results.LintProblemLocation.endOfComment(doc.comments, last_comment.?),
                        .message = try gpa.dupe(u8, "Avoid code in comments"),
                    });
                }

                content_accumulator.clearAndFree(gpa);
                first_comment = null;
                last_comment = null;
            }
            try content_accumulator.appendSlice(gpa, contents);
            try content_accumulator.append(gpa, '\n');
        }

        first_comment = first_comment orelse comment;
        last_comment = comment;
    }

    if (content_accumulator.items.len > 0) {
        if (try looksLikeCode(content_accumulator.items[0..], gpa)) {
            try lint_problems.append(gpa, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = zlinter.results.LintProblemLocation.startOfComment(doc.comments, first_comment.?),
                .end = zlinter.results.LintProblemLocation.endOfComment(doc.comments, last_comment.?),
                .message = try gpa.dupe(u8, "Avoid code in comments"),
            });
        }

        content_accumulator.clearAndFree(gpa);
        first_comment = null;
        last_comment = null;
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

fn looksLikeCode(content: []const u8, gpa: std.mem.Allocator) !bool {
    if (content.len == 0) return false;
    if (std.mem.indexOfScalar(u8, content, '`') != null) return false;

    const statement_container_fmt = "fn wrap() void {{\n{s}\n}}\n";
    const declaration_container_fmt = "{s}";

    const buffer = try gpa.allocSentinel(u8, content.len + @max(statement_container_fmt.len, declaration_container_fmt.len) + 1, 0);
    defer gpa.free(buffer);

    const looks_like_statement = looks_like_statement: {
        const container_code = std.fmt.bufPrintZ(buffer, statement_container_fmt, .{content}) catch unreachable;
        var tree = try Ast.parse(gpa, container_code, .zig);
        defer tree.deinit(gpa);

        const root_and_wrap_fn_nodes = 5;
        if (tree.nodes.len <= root_and_wrap_fn_nodes) break :looks_like_statement false;
        if (tree.errors.len > 0) break :looks_like_statement false;
        break :looks_like_statement true;
    };
    if (looks_like_statement) return true;

    const looks_like_declaration = looks_like_declaration: {
        const root_code = std.fmt.bufPrintZ(buffer, declaration_container_fmt, .{content}) catch unreachable;
        var tree = try Ast.parse(gpa, root_code, .zig);
        defer tree.deinit(gpa);

        const root_node = 1;
        if (tree.nodes.len <= root_node) break :looks_like_declaration false;
        if (tree.errors.len > 0) break :looks_like_declaration false;

        var node = NodeIndexShim.init(0);
        while (node.index < tree.nodes.len) : (node.index += 1) {
            switch (shims.nodeTag(tree, node.toNodeIndex())) {
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
                    //     std.debug.print("{} - '{s}'\n", .{ container_field.tree, tree.tokenSlice(container_field.ast.main_token) });
                    //     if (NodeIndexShim.initOptional(container_field.ast.type_expr) != null and
                    //         tree.lastToken(node.toNodeIndex()) + 1 < tree.tokens.len and
                    //         tree.tokens.items(.tag)[ast.lastToken(node.toNodeIndex()) + 1] == .comma)
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

test "looksLikeCode empty" {
    try std.testing.expect(!try looksLikeCode("", std.testing.allocator));
}

test "looksLikeCode test decl" {
    try std.testing.expect(try looksLikeCode("test \"foo\" {}", std.testing.allocator));
}

test {
    std.testing.refAllDecls(@This());
}

test "run detects commented var" {
    const rule = buildRule(.{});
    const source =
        \\// This is a regular comment
        \\
        \\// var a = 1;
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// var a = 1;\n",
                .message = "Avoid code in comments",
            },
        },
    );
}

test "run detects commented call" {
    const rule = buildRule(.{});
    const source =
        \\// This is a regular comment
        \\
        \\// std.debug.print("hi", .{});
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// std.debug.print(\"hi\", .{});\n",
                .message = "Avoid code in comments",
            },
        },
    );
}

test "run detects commented fn decl" {
    const rule = buildRule(.{});
    const source =
        \\// This is a regular comment
        \\
        \\// fn foo() u32 {
        \\//     return 10;
        \\// }
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// fn foo() u32 {\n//     return 10;\n// }\n",
                .message = "Avoid code in comments",
            },
        },
    );
}

test "run ignores plain comment" {
    const rule = buildRule(.{});
    const source =
        \\// this is a regular comment
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{},
    );
}

test "run ignores backtick code" {
    const rule = buildRule(.{});
    const source =
        \\// e.g., `var a = 1;`
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{},
    );
}

test "run multi-line block" {
    const rule = buildRule(.{});
    const source =
        \\// var a = 1;
        \\// var b = 2;
        \\// var c = 3;
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// var a = 1;\n// var b = 2;\n// var c = 3;\n",
                .message = "Avoid code in comments",
            },
        },
    );
}

test "run separate blocks" {
    const rule = buildRule(.{});
    const source =
        \\// var a = 1;
        \\
        \\const x = 1;
        \\// var b = 2;
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// var a = 1;\n",
                .message = "Avoid code in comments",
            },
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// var b = 2;\n",
                .message = "Avoid code in comments",
            },
        },
    );
}

test "run off" {
    const rule = buildRule(.{});
    const source =
        \\// var a = 1;
        \\
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

test "run end of file flush" {
    const rule = buildRule(.{});
    const source = "// var a = 1;";

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_comment_out_code",
                .severity = .warning,
                .slice = "// var a = 1;\x00",
                .message = "Avoid code in comments",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
