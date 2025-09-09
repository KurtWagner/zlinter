//! Disallows empty code blocks `{}` unless explicitly allowed or documented.
//!
//! Empty blocks are often a sign of incomplete or accidentally removed code.
//! They can make intent unclear and mislead maintainers into thinking logic
//! is missing.
//!
//! In some cases, empty blocks are intentional (e.g. placeholder, scoping, or
//! looping constructs). This rule helps distinguish between accidental
//! emptiness and intentional no-op by requiring either a configuration
//! exception or a comment.
//!
//! For example,
//!
//! ```zig
//! // OK - as comment within block.
//! if (something) {
//!   // do nothing
//! } else {
//!   doThing();
//! }
//! ```

/// Config for no_empty_block rule.
pub const Config = struct {
    /// Severity for empty `if` blocks
    if_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `while` blocks
    while_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty `for` blocks
    for_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `catch` blocks
    catch_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty switch case blocks
    switch_case_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty `defer` blocks
    defer_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `errdefer` blocks
    errdefer_block: zlinter.rules.LintProblemSeverity = .@"error",
};

/// Builds and returns the no_empty_block rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_empty_block),
        .run = &run,
    };
}

/// Runs the no_empty_block rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems: shims.ArrayList(zlinter.results.LintProblem) = .empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple;

        const statement = zlinter.ast.fullStatement(tree, node.toNodeIndex()) orelse continue :nodes;
        const severity: zlinter.rules.LintProblemSeverity = switch (statement) {
            .@"if" => config.if_block,
            .@"while" => config.while_block,
            .@"for" => config.for_block,
            .switch_case => config.switch_case_block,
            .@"catch" => config.catch_block,
            .@"defer" => config.defer_block,
            .@"errdefer" => config.errdefer_block,
        };
        if (severity == .off) continue :nodes;

        var expr_nodes_buffer: [2]Ast.Node.Index = undefined;
        var expr_nodes: shims.ArrayList(Ast.Node.Index) = .initBuffer(&expr_nodes_buffer);

        switch (statement) {
            .@"if" => |info| {
                expr_nodes.appendAssumeCapacity(info.ast.then_expr);
                if (shims.NodeIndexShim.initOptional(info.ast.else_expr)) |n| {
                    expr_nodes.appendAssumeCapacity(n.toNodeIndex());
                }
            },
            .@"while" => |info| {
                expr_nodes.appendAssumeCapacity(info.ast.then_expr);
                if (shims.NodeIndexShim.initOptional(info.ast.else_expr)) |n| {
                    expr_nodes.appendAssumeCapacity(n.toNodeIndex());
                }
            },
            .@"for" => |info| {
                expr_nodes.appendAssumeCapacity(info.ast.then_expr);
                if (shims.NodeIndexShim.initOptional(info.ast.else_expr)) |n| {
                    expr_nodes.appendAssumeCapacity(n.toNodeIndex());
                }
            },
            .switch_case => |info| expr_nodes.appendAssumeCapacity(info.ast.target_expr),
            .@"catch" => |expr_node| expr_nodes.appendAssumeCapacity(expr_node),
            .@"defer" => |expr_node| expr_nodes.appendAssumeCapacity(expr_node),
            .@"errdefer" => |expr_node| expr_nodes.appendAssumeCapacity(expr_node),
        }

        expr_nodes: for (expr_nodes.items) |expr_node| {
            // Ignore here as it'll be processed in the outer loop.
            if (zlinter.ast.fullStatement(tree, expr_node) != null) continue :expr_nodes;

            // If it's not a block we assume it's a single statement (i.e., one
            // child). Keep in mind a block may have zero statement (i.e., empty).
            // Which this rule does not care about.
            const has_braces = switch (shims.nodeTag(tree, expr_node)) {
                .block,
                .block_semicolon,
                .block_two,
                .block_two_semicolon,
                => true,
                else => false,
            };
            if (!has_braces) continue :expr_nodes;

            const first_token = tree.firstToken(expr_node);
            const last_token = tree.lastToken(expr_node);

            const start = tree.tokenStart(first_token) + tree.tokenSlice(last_token).len;
            const end = tree.tokenStart(last_token);

            for (start..end) |i| {
                if (!std.ascii.isWhitespace(tree.source[i])) {
                    continue :expr_nodes;
                }
            }

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = severity,
                .start = .startOfToken(tree, first_token),
                .end = .endOfToken(tree, last_token),
                .message = try std.fmt.allocPrint(
                    allocator,
                    "Empty blocks are discouraged inside of {s} blocks. If deliberate “do nothing”, include a comment inside the block.",
                    .{statement.name()},
                ),
            });
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

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
