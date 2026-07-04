//! Disallow boolean expressions that consist only of literal values.
//!
//! If a boolean expression always evaluates to true or false, the statement is
//! redundant and likely unintended. Remove it or replace it with a meaningful
//! condition.
//!
//! For example,
//!
//! ```zig
//! // Bad
//! if (1 == 1) {
//!   // always true
//! }
//!
//! // Bad
//! if (false) {
//!   // always false
//! }
//!
//! // Ok
//! while (true) {
//!    break;
//! }
//! ```

/// Config for no_literal_only_bool_expression rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

/// Builds and returns the no_literal_only_bool_expression rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_literal_only_bool_expression),
        .run = &run,
    };
}

/// Runs the no_literal_only_bool_expression rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        switch (tree.nodeTag(node)) {
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            => {
                if (!isNestedWithinLiteralBoolExprCondition(tree, doc, node)) {
                    const data = tree.nodeData(node);
                    const lhs, const rhs = .{ data.node_and_node[0], data.node_and_node[1] };
                    if (isLiteral(tree, unwrapGroupedExpression(tree, lhs)) != null and
                        isLiteral(tree, unwrapGroupedExpression(tree, rhs)) != null)
                    {
                        try lint_problems.append(session_arena, .{
                            .rule_id = rule.rule_id,
                            .severity = config.severity,
                            .start = .startOfNode(tree, node),
                            .end = .endOfNode(tree, node),
                            .message = try session_arena.dupe(u8, "Condition is always true or false"),
                        });
                    }
                }
            },
            else => if (tree.fullIf(node)) |full_if| {
                const cond_expr = unwrapGroupedExpression(tree, full_if.ast.cond_expr);
                if (classifyLiteralBoolExpr(tree, cond_expr) != null and
                    !isComparisonExpr(tree.nodeTag(cond_expr)))
                {
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, cond_expr),
                        .end = .endOfNode(tree, cond_expr),
                        .message = try session_arena.dupe(u8, "Condition is always true or false"),
                    });
                }
            } else if (tree.fullWhile(node)) |full_while| {
                const cond_expr = unwrapGroupedExpression(tree, full_while.ast.cond_expr);
                if (classifyLiteralBoolExpr(tree, cond_expr)) |kind| {
                    if (kind == .true_literal) continue :nodes;
                    if (isComparisonExpr(tree.nodeTag(cond_expr))) continue :nodes;

                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, cond_expr),
                        .end = .endOfNode(tree, cond_expr),
                        .message = try session_arena.dupe(u8, "Condition is always true or false"),
                    });
                }
            },
            // else if (tree.fullVarDecl(node)) |var_decl| {
            //     if (tree.tokens.items(.tag)[var_decl.ast.mut_token] != .keyword_const) continue :nodes;

            //     const init_node = var_decl.ast.init_node.unwrap() orelse continue :nodes;
            //     if (!isLiteral(tree, init_node)) continue :nodes;
            // },
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

const Literal = enum {
    false,
    true,
    number,
    char,
};

const BoolExprKind = enum {
    false_literal,
    true_literal,
    literal_only,
};

/// Does not consider string literals, only booleans, numbers and chars
fn isLiteral(tree: Ast, node: Ast.Node.Index) ?Literal {
    const unwrapped = unwrapGroupedExpression(tree, node);
    return switch (tree.nodeTag(unwrapped)) {
        .number_literal => .number,
        .char_literal => .char,
        .identifier => id: {
            const token = tree.nodeMainToken(unwrapped);
            break :id switch (tree.tokens.items(.tag)[token]) {
                .number_literal => .number,
                .char_literal => .char,
                .identifier => if (std.mem.eql(u8, tree.tokenSlice(token), "true")) .true else if (std.mem.eql(u8, tree.tokenSlice(token), "false")) .false else null,
                else => null,
            };
        },
        else => null,
    };
}

fn classifyLiteralBoolExpr(tree: Ast, node: Ast.Node.Index) ?BoolExprKind {
    const unwrapped = unwrapGroupedExpression(tree, node);
    return switch (tree.nodeTag(unwrapped)) {
        .identifier => switch (isLiteral(tree, unwrapped) orelse return null) {
            .true => .true_literal,
            .false => .false_literal,
            else => null,
        },
        .bool_not => blk: {
            const operand = tree.nodeData(unwrapped).node;
            if (classifyLiteralBoolExpr(tree, operand) == null) return null;
            break :blk .literal_only;
        },
        .bool_and,
        .bool_or,
        => blk: {
            const lhs, const rhs = tree.nodeData(unwrapped).node_and_node;
            if (classifyLiteralBoolExpr(tree, lhs) == null) return null;
            if (classifyLiteralBoolExpr(tree, rhs) == null) return null;
            break :blk .literal_only;
        },
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        => blk: {
            const lhs, const rhs = tree.nodeData(unwrapped).node_and_node;
            if (isLiteral(tree, unwrapGroupedExpression(tree, lhs)) == null) return null;
            if (isLiteral(tree, unwrapGroupedExpression(tree, rhs)) == null) return null;
            break :blk .literal_only;
        },
        else => null,
    };
}

fn isComparisonExpr(tag: Ast.Node.Tag) bool {
    return switch (tag) {
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        => true,
        else => false,
    };
}

fn isNestedWithinLiteralBoolExprCondition(tree: Ast, doc: *const zlinter.session.LintDocument, node: Ast.Node.Index) bool {
    var it = doc.nodeAncestorIterator(node);
    var seen_bool_expr = false;
    while (it.next()) |ancestor| {
        switch (tree.nodeTag(ancestor)) {
            .grouped_expression => continue,
            .bool_not,
            .bool_and,
            .bool_or,
            => {
                if (classifyLiteralBoolExpr(tree, ancestor) == null) return false;
                seen_bool_expr = true;
            },
            .if_simple,
            .@"if",
            .while_simple,
            .@"while",
            => return seen_bool_expr,
            else => return false,
        }
    }
    return false;
}

fn unwrapGroupedExpression(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (tree.nodeTag(current) == .grouped_expression) {
        current = tree.nodeData(current).node_and_token[0];
    }
    return current;
}

test "bad cases" {
    const rule = buildRule(.{});
    inline for (&.{ .warning, .@"error" }) |severity| {
        inline for (&.{
            .{ "if (1 == 1) {}", "1 == 1" },
            .{ "if ((1) == (1)) {}", "(1) == (1)" },
            .{ "if (1 <= 2) {}", "1 <= 2" },
            .{ "if (true) {}", "true" },
            .{ "if ((true)) {}", "true" },
            .{ "if (false) {}", "false" },
            .{ "if ((false)) {}", "false" },
            .{ "if (true and false) {}", "true and false" },
            .{ "if (!false) {}", "!false" },
            .{ "if ((1 == 1) and true) {}", "(1 == 1) and true" },
            .{ "if (false or false) {}", "false or false" },
            .{ "if (1 > 2) {}", "1 > 2" },
            .{ "if (2 >= 2) {}", "2 >= 2" },
            .{ "if (2 != 1) {}", "2 != 1" },
            .{ "if (1 == 1 or 1 >= a) {}", "1 == 1" },
            .{ "if (1 == a and 2 == 3) {}", "2 == 3" },
            .{ "const a = 1 == 2;", "1 == 2" },
            .{ "const a = 1 <= 2;", "1 <= 2" },
            .{ "while (false) {}", "false" },
            .{ "while ((false)) {}", "false" },
            .{ "while (1 == 1) {}", "1 == 1" },
            .{ "while (2 == 1) {}", "2 == 1" },
            .{ "while ((1) == (1)) {}", "(1) == (1)" },
        }) |tuple| {
            const source, const problem = tuple;
            try zlinter.testing.testRunRule(
                rule,
                "pub fn main() void {\n" ++ source ++ "\n}",
                .{},
                Config{ .severity = severity },
                &.{
                    .{
                        .rule_id = "no_literal_only_bool_expression",
                        .severity = severity,
                        .slice = problem,
                        .message = "Condition is always true or false",
                    },
                },
            );
        }
    }
    try zlinter.testing.testRunRule(
        rule,
        "pub fn main() void { var a = 1 == 1; }",
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

test "good cases" {
    const rule = buildRule(.{});
    inline for (&.{
        "while (true) {}",
        "while ((true)) {}",
        "if (a == 1) {}",
        "if (1 >= a) {}",
        "if (a and true) {}",
    }) |source| {
        try zlinter.testing.testRunRule(
            rule,
            "pub fn main() void {\n" ++ source ++ "\n}",
            .{},
            Config{ .severity = .warning },
            &.{},
        );
    }
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
