//! Enforces the use of braces `{}` for the bodies of `if`, `else`, `while`,
//! and `for` statements.
//!
//! By requiring braces, you avoid ambiguity, make code easier to maintain,
//! and prevent unintended logic changes when adding new lines.
//!
//! If an `if` statement is used as part of a return or assignment it is excluded
//! from this rule (braces not required). For example, the following two examples
//! will be ignored by this rule.
//!
//! ```zig
//! const label = if (x > 10) "over 10" else "under 10";
//! ```
//!
//! and
//!
//! ```zig
//! return if (x > 20)
//!    "over 20"
//! else
//!    "under 20";
//! ```

// TODO: Consider `catch`
// TODO: Consider `switch` cases

/// Config for require_braces rule.
pub const Config = struct {
    /// The severity when require braces problem is found.
    severity: zlinter.rules.LintProblemSeverity = .@"error",

    /// Whether or not to include cases where the condition is on the same
    /// line as the expression or to only require when spans multiple lines.
    requirement: enum {
        /// Use braces all the time
        all,
        /// Must only use braces when there's multiple statements within a block
        multi,
        /// Must use braces when the statement is on a new line
        multiline,
    } = .multiline,
};

/// Builds and returns the require_braces rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_braces),
        .run = &run,
    };
}

/// Runs the require_braces rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const statement = fullStatement(tree, node.toNodeIndex()) orelse continue :nodes;

        // Skip if part of an assignment or return statement as braces are omitted
        switch (shims.nodeTag(tree, connections.parent.?)) {
            .@"return",
            .simple_var_decl,
            .local_var_decl,
            .global_var_decl,
            .aligned_var_decl,
            => continue :nodes,
            else => {},
        }

        var nodes: [2]Ast.Node.Index = undefined;

        switch (statement) {
            .@"if" => |info| {
                nodes[0] = info.ast.then_expr;
            },
            .@"while" => |info| {
                nodes[0] = info.ast.then_expr;
            },
            .@"for" => |info| {
                nodes[0] = info.ast.then_expr;
            },
        }

        const first_token = tree.firstToken(nodes[0]);
        const last_token = tree.lastToken(nodes[0]);

        const first_token_tag = shims.tokenTag(tree, first_token);

        switch (config.requirement) {
            // Use braces all the time
            .all => {
                if (first_token_tag != .l_brace) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfToken(tree, first_token),
                        .end = .endOfToken(tree, last_token),
                        .message = try allocator.dupe(u8, "Requires braces"),
                    });
                }
            },
            // Only use braces when there's multiple statements within a block
            .multi => {
                const children_count = (doc.lineage.items(.children)[nodes[0]] orelse &.{}).len;
                if (children_count > 1) {
                    if (first_token_tag != .l_brace) {
                        try lint_problems.append(allocator, .{
                            .rule_id = rule.rule_id,
                            .severity = config.severity,
                            .start = .startOfToken(tree, first_token),
                            .end = .endOfToken(tree, last_token),
                            .message = try allocator.dupe(u8, "Requires braces"),
                        });
                    }
                } else if (first_token_tag == .l_brace) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfToken(tree, first_token),
                        .end = .endOfToken(tree, last_token),
                        .message = try allocator.dupe(u8, "Requires no braces"),
                    });
                }
            },
            // Must use braces when the statement is on a new line
            .multiline => {
                if (tree.tokensOnSameLine(first_token, last_token)) {
                    if (first_token_tag == .l_brace) {
                        try lint_problems.append(allocator, .{
                            .rule_id = rule.rule_id,
                            .severity = config.severity,
                            .start = .startOfToken(tree, first_token),
                            .end = .endOfToken(tree, last_token),
                            .message = try allocator.dupe(u8, "Requires no braces"),
                        });
                    }
                } else if (first_token_tag != .l_brace) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfToken(tree, first_token),
                        .end = .endOfToken(tree, last_token),
                        .message = try allocator.dupe(u8, "Requires braces"),
                    });
                }
            },
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

const Statement = union(enum) {
    @"if": Ast.full.If,
    @"while": Ast.full.While,
    @"for": Ast.full.For,
};

fn fullStatement(tree: Ast, node: Ast.Node.Index) ?Statement {
    return if (tree.fullIf(node)) |ifStatement|
        .{ .@"if" = ifStatement }
    else if (tree.fullWhile(node)) |whileStatement|
        .{ .@"while" = whileStatement }
    else if (tree.fullFor(node)) |forStatement|
        .{ .@"for" = forStatement }
    else
        null;
}

const std = @import("std");
const Ast = std.zig.Ast;
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
