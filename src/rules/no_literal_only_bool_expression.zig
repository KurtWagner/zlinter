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
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        switch (shims.nodeTag(tree, node.toNodeIndex())) {
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            => {
                const data = shims.nodeData(tree, node.toNodeIndex());
                const lhs, const rhs = switch (zlinter.version.zig) {
                    .@"0.14" => .{ data.lhs, data.rhs },
                    .@"0.15", .@"0.16" => .{ data.node_and_node[0], data.node_and_node[1] },
                };
                if (isLiteral(tree, lhs) != null and isLiteral(tree, rhs) != null) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, node.toNodeIndex()),
                        .end = .endOfNode(tree, node.toNodeIndex()),
                        .message = try allocator.dupe(u8, "Useless condition"),
                    });
                }
            },
            else => if (tree.fullIf(node.toNodeIndex())) |full_if| {
                if (isLiteral(tree, full_if.ast.cond_expr)) |_| {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, full_if.ast.cond_expr),
                        .end = .endOfNode(tree, full_if.ast.cond_expr),
                        .message = try allocator.dupe(u8, "Useless condition"),
                    });
                }
            } else if (tree.fullWhile(node.toNodeIndex())) |full_while| {
                if (isLiteral(tree, full_while.ast.cond_expr)) |literal| {
                    if (literal == .true) continue :nodes;

                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, full_while.ast.cond_expr),
                        .end = .endOfNode(tree, full_while.ast.cond_expr),
                        .message = try allocator.dupe(u8, "Useless condition"),
                    });
                }
            },
            // else if (tree.fullVarDecl(node.toNodeIndex())) |var_decl| {
            //     if (tree.tokens.items(.tag)[var_decl.ast.mut_token] != .keyword_const) continue :nodes;

            //     const init_node = NodeIndexShim.initOptional(var_decl.ast.init_node) orelse continue :nodes;
            //     if (!isLiteral(tree, init_node.toNodeIndex())) continue :nodes;
            // },
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
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

/// Does not consider string literals, only booleans, numbers and chars
fn isLiteral(tree: Ast, node: Ast.Node.Index) ?Literal {
    return switch (shims.nodeTag(tree, node)) {
        .number_literal => .number,
        .char_literal => .char,
        .identifier => id: {
            const token = shims.nodeMainToken(tree, node);
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

test "bad cases" {
    const rule = buildRule(.{});
    inline for (&.{ .warning, .@"error" }) |severity| {
        inline for (&.{
            .{ "if (1 == 1) {}", "1 == 1" },
            .{ "if (1 <= 2) {}", "1 <= 2" },
            .{ "if (true) {}", "true" },
            .{ "if (false) {}", "false" },
            .{ "if (1 > 2) {}", "1 > 2" },
            .{ "if (2 >= 2) {}", "2 >= 2" },
            .{ "if (2 != 1) {}", "2 != 1" },
            .{ "if (1 == 1 or 1 >= a) {}", "1 == 1" },
            .{ "if (1 == a and 2 == 3) {}", "2 == 3" },
            .{ "const a = 1 == 2;", "1 == 2" },
            .{ "const a = 1 <= 2;", "1 <= 2" },
            .{ "while (false) {}", "false" },
            .{ "while (1 == 1) {}", "1 == 1" },
            .{ "while (2 == 1) {}", "2 == 1" },
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
                        .message = "Useless condition",
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
        "if (a == 1) {}",
        "if (1 >= a) {}",
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
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
