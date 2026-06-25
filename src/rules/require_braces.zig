//! Requires specific brace `{}` usage for the bodies of `if`, `else`, `while`,
//! `for`, `defer` and `catch` statements.
//!
//! By requiring braces, you're consistent and avoid ambiguity, which can code
//! easier to maintain, and prevent unintended logic changes when adding new
//! lines.
//!
//! If an `if` statement is used as part of a return or assignment it is excluded
//! from this rule (braces not required).
//!
//! For example, the following two examples will be ignored by this rule.
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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const statement = zlinter.ast.fullStatement(tree, node) orelse
            continue :nodes;

        if (!isStatementBodyContext(
            tree,
            doc,
            node,
            connections,
        ))
            continue :nodes;

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
        var expr_nodes: std.ArrayList(Ast.Node.Index) = .initBuffer(&expr_nodes_buffer);

        switch (statement) {
            .@"if" => |info| {
                expr_nodes.appendAssumeCapacity(info.ast.then_expr);
                if (info.ast.else_expr.unwrap()) |n|
                    expr_nodes.appendAssumeCapacity(n);
            },
            .@"while" => |info| {
                expr_nodes.appendAssumeCapacity(info.ast.then_expr);
                if (info.ast.else_expr.unwrap()) |n|
                    expr_nodes.appendAssumeCapacity(n);
            },
            .@"for" => |info| {
                expr_nodes.appendAssumeCapacity(info.ast.then_expr);
                if (info.ast.else_expr.unwrap()) |n|
                    expr_nodes.appendAssumeCapacity(n);
            },
            .switch_case => |info| expr_nodes.appendAssumeCapacity(info.ast.target_expr),
            .@"catch" => |expr_node| expr_nodes.appendAssumeCapacity(expr_node),
            .@"defer" => |expr_node| expr_nodes.appendAssumeCapacity(expr_node),
            .@"errdefer" => |expr_node| expr_nodes.appendAssumeCapacity(expr_node),
        }

        expr_nodes: for (expr_nodes.items) |expr_node| {
            // Ignore here as it'll be processed in the outer loop.
            if (zlinter.ast.fullStatement(tree, expr_node) != null)
                continue :expr_nodes;

            // If it's not a block we assume it's a single statement (i.e., one
            // child). Keep in mind a block may have zero statement (i.e., empty).
            // Which this rule does not care about.
            const has_braces = switch (tree.nodeTag(expr_node)) {
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
                        if (!has_braces)
                            break :error_msg try session_arena.dupe(
                                u8,
                                "Expects braces whether on a single or across multiple lines",
                            );
                    },
                    .multi_statement_only => {
                        if (has_braces) {
                            const children = doc.lineage.items(.children)[@intFromEnum(expr_node)] orelse &.{};
                            if (children.len == 1)
                                break :error_msg try session_arena.dupe(
                                    u8,
                                    "Expects no braces when there's only one statement",
                                );
                        }
                    },
                    .multi_line_only => {
                        const on_single_line = tree.tokensOnSameLine(first_token, last_token);
                        if (on_single_line and has_braces) {
                            const children = doc.lineage.items(.children)[@intFromEnum(expr_node)] orelse
                                &.{};
                            if (children.len > 0) // We allow empy blocks / no children
                                break :error_msg try session_arena.dupe(
                                    u8,
                                    "Expects no braces when on a single line",
                                );
                        }

                        if (!has_braces and
                            bodyStartsOnNewLine(tree, expr_node))
                            break :error_msg try session_arena.dupe(
                                u8,
                                "Expects braces when over multiple lines",
                            );
                    },
                }
                continue :expr_nodes;
            };

            try lint_problems.append(session_arena, .{
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
            session_arena,
            doc.absPath(session),
            lint_problems.items,
        )
    else
        null;
}

/// Returns true when `node` is control flow whose body is acting as a
/// statement body, and false when the same syntax is only part of an expression.
///
/// Checked:
///
/// ```zig
/// if (ok)
///     doThing();
///
/// if (ok)
///     if (nested)
///         doThing();
/// ```
///
/// Ignored:
///
/// ```zig
/// consume(if (ok) 1 else 2);
/// const value = (if (ok) 1 else 2) + 3;
/// ```
fn isStatementBodyContext(
    tree: Ast,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    connections: zlinter.ast.NodeConnections,
) bool {
    const parent = connections.parent orelse return false;

    if (isExpressionContextToSkip(
        tree,
        node,
        connections,
    ))
        return false;

    if (zlinter.ast.isBlock(tree, parent))
        return true;

    if (isSwitchCaseNode(tree, node) and
        isSwitchNode(tree, parent))
        return isNodeInStatementBodyContext(tree, doc, parent);

    return isBodyExprOfStatement(tree, parent, node) and
        isNodeInStatementBodyContext(tree, doc, parent);
}

/// Re-runs statement-body context detection for an ancestor node.
///
/// This lets nested body syntax inherit the outer statement context:
///
/// ```zig
/// if (ok)
///     switch (mode) {
///         .a => doA(),
///         else => doB(),
///     };
/// ```
///
/// But an expression-valued ancestor still blocks linting:
///
/// ```zig
/// const value = switch (mode) {
///     .a => if (ok) 1 else 2,
///     else => 3,
/// };
/// ```
fn isNodeInStatementBodyContext(
    tree: Ast,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
) bool {
    return isStatementBodyContext(
        tree,
        doc,
        node,
        doc.lineage.get(@intFromEnum(node)),
    );
}

/// Returns true when `node` is an expression value position that this rule
/// intentionally ignores.
fn isExpressionContextToSkip(
    tree: Ast,
    node: Ast.Node.Index,
    connections: zlinter.ast.NodeConnections,
) bool {
    const parent = connections.parent orelse return false;

    return switch (tree.nodeTag(parent)) {
        .@"return" => optionalNodeEquals(tree.nodeData(parent).opt_node, node),
        .global_var_decl,
        .local_var_decl,
        .simple_var_decl,
        .aligned_var_decl,
        => optionalNodeEquals(tree.fullVarDecl(parent).?.ast.init_node, node),
        .assign_mul,
        .assign_div,
        .assign_mod,
        .assign_add,
        .assign_sub,
        .assign_shl,
        .assign_shl_sat,
        .assign_shr,
        .assign_bit_and,
        .assign_bit_xor,
        .assign_bit_or,
        .assign_mul_wrap,
        .assign_add_wrap,
        .assign_sub_wrap,
        .assign_mul_sat,
        .assign_add_sat,
        .assign_sub_sat,
        .assign,
        => tree.nodeData(parent).node_and_node[1] == node,
        .assign_destructure => tree.nodeData(parent).extra_and_node[1] == node,
        else => false,
    };
}

/// Returns true when `body_node` is the body-like child of `statement_node`,
/// rather than a condition, payload, switch value, or other expression child.
///
/// Checked children include:
///
/// ```zig
/// if (ok)
///     doThing() // then body
/// else
///     doOther(); // else body
///
/// defer doThing(); // defer expression
/// ```
fn isBodyExprOfStatement(tree: Ast, statement_node: Ast.Node.Index, body_node: Ast.Node.Index) bool {
    const statement = zlinter.ast.fullStatement(tree, statement_node) orelse
        return false;

    return switch (statement) {
        .@"if" => |info| body_node == info.ast.then_expr or
            optionalNodeEquals(info.ast.else_expr, body_node),
        .@"while" => |info| body_node == info.ast.then_expr or
            optionalNodeEquals(info.ast.else_expr, body_node),
        .@"for" => |info| body_node == info.ast.then_expr or
            optionalNodeEquals(info.ast.else_expr, body_node),
        .switch_case => |info| body_node == info.ast.target_expr,
        .@"catch" => |expr_node| body_node == expr_node,
        .@"defer" => |expr_node| body_node == expr_node,
        .@"errdefer" => |expr_node| body_node == expr_node,
    };
}

/// Compares optional AST children such as `if` / `while` / `for` else bodies.
///
/// ```zig
/// if (ok)
///     doThing()
/// else
///     doOther(); // compared through Ast.Node.OptionalIndex
/// ```
fn optionalNodeEquals(optional_node: Ast.Node.OptionalIndex, node: Ast.Node.Index) bool {
    return if (optional_node.unwrap()) |unwrapped|
        unwrapped == node
    else
        false;
}

/// Returns true when a body expression starts on a different line than the token
/// immediately before it.
fn bodyStartsOnNewLine(tree: Ast, body_node: Ast.Node.Index) bool {
    const first_token = tree.firstToken(body_node);
    if (first_token == 0)
        return false;
    return !tree.tokensOnSameLine(first_token - 1, first_token);
}

/// Returns true for switch expression nodes that own switch case nodes.
///
/// ```zig
/// switch (mode) {
///     .a => doA(),
///     else => doB(),
/// }
/// ```
fn isSwitchNode(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"switch",
        .switch_comma,
        => true,
        else => false,
    };
}

/// Returns true for every switch case node shape, including single-item and
/// inline cases.
///
/// ```zig
/// switch (mode) {
///     .a => doA(), // switch case
///     inline .b => doB(), // inline switch case
///     else => doOther(),
/// }
/// ```
fn isSwitchCaseNode(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .switch_case_one,
        .switch_case_inline_one,
        .switch_case,
        .switch_case_inline,
        => true,
        else => false,
    };
}

const if_statement_source =
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

test "if_statement all reports unbraced statement bodies" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        if_statement_source,
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
}

test "if_statement off reports no problems" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        if_statement_source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .all,
                .severity = .off,
            },
        },
        &.{},
    );
}

test "if_statement multi_line_only reports bodies that start on new lines" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        if_statement_source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .multi_line_only,
                .severity = .@"error",
            },
        },
        &.{
            .{
                .rule_id = "require_braces",
                .severity = .@"error",
                .slice = "a = 4",
                .message = "Expects braces when over multiple lines",
            },
        },
    );
}

test "if_statement multi_statement_only reports single-statement blocks" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        if_statement_source,
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

test "multi_line_only reports one-line bodies that start on the next line" {
    const source =
        \\fn enabled() bool {
        \\    return true;
        \\}
        \\
        \\fn items() []const u8 {
        \\    return "abc";
        \\}
        \\
        \\fn fallible() !u8 {
        \\    return error.Fail;
        \\}
        \\
        \\fn ifBody() void {}
        \\fn elseBody() void {}
        \\fn whileBody() void {}
        \\fn forBody() void {}
        \\fn catchBody() u8 { return 0; }
        \\fn deferBody() void {}
        \\fn errdeferBody() void {}
        \\
        \\pub fn main() void {
        \\    if (enabled())
        \\        ifBody();
        \\
        \\    if (enabled()) {
        \\        ifBody();
        \\    } else
        \\        elseBody();
        \\
        \\    while (enabled())
        \\        whileBody();
        \\
        \\    for (items()) |_|
        \\        forBody();
        \\
        \\    fallible() catch
        \\        catchBody();
        \\
        \\    defer
        \\        deferBody();
        \\
        \\    errdefer
        \\        errdeferBody();
        \\
        \\    if (enabled()) { ifBody(); }
        \\}
    ;

    const multi_line_only = RequirementAndSeverity{
        .requirement = .multi_line_only,
        .severity = .warning,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = multi_line_only,
            .while_statement = multi_line_only,
            .for_statement = multi_line_only,
            .catch_statement = multi_line_only,
            .defer_statement = multi_line_only,
            .errdefer_statement = multi_line_only,
        },
        &.{
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "{ ifBody(); }",
                .message = "Expects no braces when on a single line",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "errdeferBody()",
                .message = "Expects braces when over multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "deferBody()",
                .message = "Expects braces when over multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "catchBody()",
                .message = "Expects braces when over multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "forBody()",
                .message = "Expects braces when over multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "whileBody()",
                .message = "Expects braces when over multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "elseBody()",
                .message = "Expects braces when over multiple lines",
            },
            .{
                .rule_id = "require_braces",
                .severity = .warning,
                .slice = "ifBody()",
                .message = "Expects braces when over multiple lines",
            },
        },
    );
}

test "if expressions in non-statement positions are ignored" {
    const source =
        \\const Item = struct {
        \\    value: u32,
        \\};
        \\
        \\fn consume(_: u32) void {}
        \\
        \\pub fn main() void {
        \\    const a = true;
        \\    const b = false;
        \\
        \\    consume(if (a)
        \\        1
        \\    else
        \\        2);
        \\
        \\    const item = Item{
        \\        .value = if (a)
        \\            1
        \\        else
        \\            2,
        \\    };
        \\
        \\    const array = [_]u32{
        \\        if (a)
        \\            1
        \\        else
        \\            2,
        \\        if (b) 3 else 4,
        \\    };
        \\
        \\    const sum = (if (a)
        \\        1
        \\    else
        \\        2) + (if (b) 3 else 4);
        \\
        \\    const indexed = array[if (a) 0 else 1];
        \\    const unwrapped = (if (a) @as(?u32, 1) else null) orelse 0;
        \\    _ = .{ item, indexed, unwrapped, sum };
        \\
        \\    _ = switch (sum) {
        \\        0 => if (a)
        \\            1
        \\        else
        \\            2,
        \\        else => 3,
        \\    };
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .all,
                .severity = .warning,
            },
            .switch_case_statement = .{
                .requirement = .all,
                .severity = .warning,
            },
        },
        &.{},
    );
}

test "control-flow expressions in assignment values are ignored" {
    const source =
        \\pub fn main() void {
        \\    const a = true;
        \\    const b = false;
        \\    var assigned: u32 = 0;
        \\
        \\    assigned = if (a)
        \\        1
        \\    else
        \\        2;
        \\
        \\    assigned += if (b)
        \\        3
        \\    else
        \\        4;
        \\
        \\    assigned = if (a)
        \\        if (b)
        \\            5
        \\        else
        \\            6
        \\    else
        \\        7;
        \\
        \\    var left: u32 = 0;
        \\    var right: u32 = 0;
        \\    left, right = if (a)
        \\        .{ 8, 9 }
        \\    else
        \\        .{ 10, 11 };
        \\
        \\    assigned = switch (assigned) {
        \\        0 => if (a)
        \\            1
        \\        else
        \\            2,
        \\        else => 3,
        \\    };
        \\
        \\    _ = .{ assigned, left, right };
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_statement = .{
                .requirement = .all,
                .severity = .warning,
            },
            .switch_case_statement = .{
                .requirement = .all,
                .severity = .warning,
            },
        },
        &.{},
    );
}

const std = @import("std");
const Ast = std.zig.Ast;
const zlinter = @import("zlinter");

test {
    std.testing.refAllDecls(@This());
}
