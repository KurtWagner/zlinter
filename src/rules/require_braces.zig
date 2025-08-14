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

/// Config for require_braces rule.
pub const Config = struct {
    if_statement: RequirementAndSeverity = .{
        .severity = .warning,
        .requirement = .multiline,
    },

    while_statement: RequirementAndSeverity = .{
        .severity = .off,
        .requirement = .multiline,
    },

    for_statement: RequirementAndSeverity = .{
        .severity = .warning,
        .requirement = .multiline,
    },

    catch_statement: RequirementAndSeverity = .{
        .severity = .warning,
        .requirement = .multiline,
    },

    switch_case_statement: RequirementAndSeverity = .{
        .severity = .off,
        .requirement = .multiline,
    },
};

pub const RequirementAndSeverity = struct {
    severity: zlinter.rules.LintProblemSeverity,
    requirement: Requirement,
};

pub const Requirement = enum {
    /// Use braces all the time
    all,
    /// Must only use braces when there's multiple statements within a block
    multi,
    /// Must use braces when the statement is on a new line
    multiline,
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

        const req_and_severity: RequirementAndSeverity = switch (statement) {
            .@"if" => config.if_statement,
            .@"while" => config.while_statement,
            .@"for" => config.for_statement,
            .switch_case => config.switch_case_statement,
            .@"catch" => config.catch_statement,
        };

        switch (statement) {
            .@"if" => |info| {
                nodes[0] = info.ast.then_expr;
                if (shims.NodeIndexShim.initOptional(info.ast.else_expr)) |n| {
                    nodes[1] = n.toNodeIndex();

                    std.debug.print(
                        "ELSE {} '{s}'\n",
                        .{
                            shims.nodeTag(tree, nodes[1]),
                            tree.getNodeSource(nodes[1]),
                        },
                    );
                }
            },
            .@"while" => |info| {
                nodes[0] = info.ast.then_expr;
                if (shims.NodeIndexShim.initOptional(info.ast.else_expr)) |n| {
                    nodes[1] = n.toNodeIndex();
                }
            },
            .@"for" => |info| {
                nodes[0] = info.ast.then_expr;
                if (shims.NodeIndexShim.initOptional(info.ast.else_expr)) |n| {
                    nodes[1] = n.toNodeIndex();
                }
            },
            .switch_case => |info| {
                nodes[0] = info.ast.target_expr;
            },
            .@"catch" => |block_node| {
                nodes[0] = block_node;
            },
        }

        const first_token = tree.firstToken(nodes[0]);
        const last_token = tree.lastToken(nodes[0]);

        const first_token_tag = shims.tokenTag(tree, first_token);

        switch (req_and_severity.requirement) {
            // Use braces all the time
            .all => {
                if (first_token_tag != .l_brace) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = req_and_severity.severity,
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
                            .severity = req_and_severity.severity,
                            .start = .startOfToken(tree, first_token),
                            .end = .endOfToken(tree, last_token),
                            .message = try allocator.dupe(u8, "Requires braces"),
                        });
                    }
                } else if (first_token_tag == .l_brace) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = req_and_severity.severity,
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
                            .severity = req_and_severity.severity,
                            .start = .startOfToken(tree, first_token),
                            .end = .endOfToken(tree, last_token),
                            .message = try allocator.dupe(u8, "Requires no braces"),
                        });
                    }
                } else if (first_token_tag != .l_brace) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = req_and_severity.severity,
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
    switch_case: Ast.full.SwitchCase,
    @"catch": Ast.Node.Index,
};

fn fullStatement(tree: Ast, node: Ast.Node.Index) ?Statement {
    return if (tree.fullIf(node)) |ifStatement|
        .{ .@"if" = ifStatement }
    else if (tree.fullWhile(node)) |whileStatement|
        .{ .@"while" = whileStatement }
    else if (tree.fullFor(node)) |forStatement|
        .{ .@"for" = forStatement }
    else if (tree.fullSwitchCase(node)) |switchStatement|
        .{ .switch_case = switchStatement }
    else if (shims.nodeTag(tree, node) == .@"catch")
        .{
            .@"catch" = switch (zlinter.version.zig) {
                .@"0.14" => shims.nodeData(tree, node).rhs,
                .@"0.15" => shims.nodeData(tree, node).node_and_node[1],
            },
        }
    else
        null;
}

const std = @import("std");
const Ast = std.zig.Ast;
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
