//! > [!WARNING]
//! > The `require_braces` rule is still under testing and development. It may
//! > not work as expected and may change without notice.
//!
//! Requires specific brace `{}` usage for the bodies of `if`, `else`, `while`,
//! `for`, `defer` and `catch` statements.
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
    /// Requirement for `if` statements
    if_statement: RequirementAndSeverity = .{
        .severity = .warning,
        .requirement = .multi_line_only,
    },

    /// Requirement for `while` statements
    while_statement: RequirementAndSeverity = .{
        .severity = .off,
        .requirement = .multi_line_only,
    },

    /// Requirement for for statements
    for_statement: RequirementAndSeverity = .{
        .severity = .warning,
        .requirement = .multi_line_only,
    },

    /// Requirement for `catch` statements
    catch_statement: RequirementAndSeverity = .{
        .severity = .warning,
        .requirement = .multi_line_only,
    },

    /// Requirement for `switch` statements
    switch_case_statement: RequirementAndSeverity = .{
        .severity = .off,
        .requirement = .multi_line_only,
    },

    /// Requirement for `defer` statements
    defer_statement: RequirementAndSeverity = .{
        .severity = .off,
        .requirement = .multi_line_only,
    },

    /// Requirement for `errdefer` statements
    errdefer_statement: RequirementAndSeverity = .{
        .severity = .off,
        .requirement = .multi_line_only,
    },
};

pub const RequirementAndSeverity = struct {
    severity: zlinter.rules.LintProblemSeverity,
    requirement: Requirement,
};

pub const Requirement = enum {
    /// Require braces all the time.
    all,
    /// Must only use braces when there's multiple statements within a block
    /// unless block is empty. All others scenarios must not use braces.
    multi_statement_only,
    /// Must only use braces when the statement **starts** on a new line.
    multi_line_only,
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
    doc: *zlinter.session.LintDocument,
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

        const statement = zlinter.ast.fullStatement(tree, node.toNodeIndex()) orelse continue :nodes;

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

        const req_and_severity: RequirementAndSeverity = switch (statement) {
            .@"if" => config.if_statement,
            .@"while" => config.while_statement,
            .@"for" => config.for_statement,
            .switch_case => config.switch_case_statement,
            .@"catch" => config.catch_statement,
            .@"defer" => config.defer_statement,
            .@"errdefer" => config.errdefer_statement,
        };
        if (req_and_severity.severity == .off) continue :nodes;

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

            const first_token = tree.firstToken(expr_node);
            const last_token = tree.lastToken(expr_node);

            const error_msg = error_msg: {
                switch (req_and_severity.requirement) {
                    .all => {
                        if (!has_braces) {
                            break :error_msg try allocator.dupe(u8, "Expects braces whether on a single or across multiple lines");
                        }
                    },
                    .multi_statement_only => {
                        if (has_braces) {
                            const children_count = (doc.lineage.items(.children)[shims.NodeIndexShim.init(expr_node).index] orelse &.{}).len;
                            if (children_count == 1) {
                                break :error_msg try allocator.dupe(u8, "Expects no braces when there's only one statement");
                            }
                        }
                    },
                    .multi_line_only => {
                        const on_single_line = tree.tokensOnSameLine(first_token, last_token);
                        if (on_single_line) {
                            const children_count = (doc.lineage.items(.children)[shims.NodeIndexShim.init(expr_node).index] orelse &.{}).len;
                            if (has_braces and children_count > 0) { // We allow empy blocks / no children
                                break :error_msg try allocator.dupe(u8, "Expects no braces when on a single line");
                            }
                        } else if (!has_braces) {
                            const starts_on_same_line = tree.tokensOnSameLine(first_token - 1, first_token);
                            if (!starts_on_same_line) {
                                break :error_msg try allocator.dupe(u8, "Expects braces when over multiple lines");
                            }
                        }
                    },
                }
                continue :expr_nodes;
            };

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = req_and_severity.severity,
                .start = .startOfToken(tree, first_token),
                .end = .endOfToken(tree, last_token),
                .message = error_msg,
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

test "if statements" {
    const source =
        \\ pub fn main() u32 {
        \\     var a: u32 = 1;
        \\     if (a == 1) {
        \\         a = 2;
        \\     } else if (a == 2)
        \\         a = 4
        \\     else switch (mode) {
        \\         .on => a = 5,
        \\         else => a = 3,
        \\     }
        \\
        \\     if (a == 2) {
        \\         a = 3;
        \\     } else {
        \\         switch (mode) {
        \\             .on => a = 5,
        \\             else => a = 3,
        \\         }
        \\     }
        \\
        \\     const b = if (a == 3) 10 else 11;
        \\
        \\     const c = if (a == 3)
        \\         10
        \\     else
        \\         11;
        \\
        \\     return if (b == 10 or c == 11) 12 else 13;
        \\ }
    ;

    // if statement with 'all' requirement
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .all,
                .severity = .warning,
            },
        },
        &.{
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "a = 4",
                .message = "Expects braces whether on a single or across multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice =
                \\switch (mode) {
                \\         .on => a = 5,
                \\         else => a = 3,
                \\     }
                ,
                .message = "Expects braces whether on a single or across multiple lines",
            },
        },
    );

    // if statement with 'all' requirement but off
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .all,
                .severity = .off,
            },
        },
        &.{},
    );

    // if statement with 'multi_line_only' requirement
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .multi_line_only,
                .severity = .@"error",
            },
        },
        &.{},
    );

    // if statement with 'multi_statement_only' requirement
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .multi_statement_only,
                .severity = .@"error",
            },
        },
        &.{
            .{
                .rule_id = "require_braces",
                .severity = .@"error",
                .slice =
                \\{
                \\         a = 3;
                \\     }
                ,
                .message = "Expects no braces when there's only one statement",
            },
            .{
                .rule_id = "require_braces",
                .severity = .@"error",
                .slice =
                \\{
                \\         switch (mode) {
                \\             .on => a = 5,
                \\             else => a = 3,
                \\         }
                \\     }
                ,
                .message = "Expects no braces when there's only one statement",
            },
            .{
                .rule_id = "require_braces",
                .severity = .@"error",
                .slice =
                \\{
                \\         a = 2;
                \\     }
                ,
                .message = "Expects no braces when there's only one statement",
            },
        },
    );
}

const std = @import("std");
const Ast = std.zig.Ast;
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
