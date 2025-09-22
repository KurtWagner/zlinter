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

const problem_msg_template = "Empty {s} blocks are discouraged. If deliberately empty, include a comment inside the block.";

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

    /// Severity for empty `fn` declaration blocks
    fn_decl_block: zlinter.rules.LintProblemSeverity = .@"error",
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
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
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

        if (fnDeclBlock(tree, node.toNodeIndex())) |block| {
            if (config.fn_decl_block != .off and isEmptyBlock(tree, block)) {
                try lint_problems.append(allocator, .{
                    .rule_id = rule.rule_id,
                    .severity = config.fn_decl_block,
                    .start = .startOfToken(tree, tree.firstToken(block)),
                    .end = .endOfToken(tree, tree.lastToken(block)),
                    .message = try std.fmt.allocPrint(
                        allocator,
                        problem_msg_template,
                        .{"function declaration"},
                    ),
                });
            }
            continue :nodes;
        }

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

            if (!isEmptyBlock(tree, expr_node)) continue :expr_nodes;

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = severity,
                .start = .startOfToken(tree, tree.firstToken(expr_node)),
                .end = .endOfToken(tree, tree.lastToken(expr_node)),
                .message = try std.fmt.allocPrint(
                    allocator,
                    problem_msg_template,
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

fn isEmptyBlock(tree: Ast, node: Ast.Node.Index) bool {
    const is_block = switch (shims.nodeTag(tree, node)) {
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => true,
        else => false,
    };
    if (!is_block) return false;

    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);

    const start = tree.tokens.items(.start)[first_token] + tree.tokenSlice(last_token).len;
    const end = tree.tokens.items(.start)[last_token];

    for (start..end) |i| {
        if (!std.ascii.isWhitespace(tree.source[i])) {
            return false;
        }
    }
    return true;
}

fn fnDeclBlock(tree: Ast, node: Ast.Node.Index) ?Ast.Node.Index {
    return switch (shims.nodeTag(tree, node)) {
        .fn_decl => switch (zlinter.version.zig) {
            .@"0.14" => shims.nodeData(tree, node).rhs,
            .@"0.15", .@"0.16" => shims.nodeData(tree, node).node_and_node.@"1",
        },
        else => null,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "if blocks" {
    const source =
        \\pub fn main() void {
        \\ if (true) {}
        \\ else {}
        \\
        \\ if (false) {
        \\ } else {
        \\ 
        \\ }
        \\
        \\ if (false) {
        \\  // Deliberate
        \\ } else {
        \\  // Ignore
        \\ }
        \\
        \\ if (true) {
        \\  return;
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .if_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\ }
                    ,
                    .message = "Empty if blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\ 
                    \\ }
                    ,
                    .message = "Empty if blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .if_block = .off },
        &.{},
    );
}

test "while blocks" {
    const source =
        \\pub fn main() void {
        \\ var i: u32 = 0;
        \\ while (i > 1) {}
        \\ 
        \\ while (i > 1) {
        \\
        \\ }
        \\
        \\ while (i < 10) : (i += 1) {}
        \\
        \\ while (i < 10) : (i += 1) {
        \\   // deliberate
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .while_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty while blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty while blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty while blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .while_block = .off },
        &.{},
    );
}

test "for blocks" {
    const source =
        \\pub fn main() void {
        \\ for (0..1) |_| {}
        \\ 
        \\ for (0..1) |_| {
        \\
        \\ }
        \\
        \\ for (0..1) |_| {
        \\  // deliberate
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .for_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty for blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty for blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .for_block = .off },
        &.{},
    );
}

test "defer blocks" {
    const source =
        \\pub fn main() void {
        \\ defer {}
        \\
        \\ defer {
        \\
        \\ }
        \\
        \\ defer {
        \\  // Deliberate - maybe a TODO to cleanup
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .defer_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty defer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty defer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .defer_block = .off },
        &.{},
    );
}

test "errdefer blocks" {
    const source =
        \\pub fn main() void {
        \\ errdefer {}
        \\
        \\ errdefer {
        \\
        \\ }
        \\
        \\ errdefer {
        \\  // Deliberate - maybe a TODO to cleanup
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .errdefer_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty errdefer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty errdefer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .errdefer_block = .off },
        &.{},
    );
}

test "catch blocks" {
    const source =
        \\pub fn main() void {
        \\ something() catch {};
        \\
        \\ something() catch {
        \\
        \\ };
        \\
        \\ something() catch {
        \\  // Deliberate - maybe a TODO to cleanup
        \\ };
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .catch_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty catch blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty catch blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .catch_block = .off },
        &.{},
    );
}

test "switch case blocks" {
    const source =
        \\pub fn main() void {
        \\ const something: enum { a, b, c } = .a;
        \\ switch (something) {
        \\     .a => {},
        \\     .b => {
        \\
        \\     },
        \\     .c => {
        \\         // Ignore
        \\     },
        \\ }
        \\ }
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .switch_case_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\     }
                    ,
                    .message = "Empty switch case blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty switch case blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .switch_case_block = .off },
        &.{},
    );
}

test "function declaration blocks" {
    const source =
        \\pub fn empty() void {}
        \\
        \\pub fn alsoEmpty() void {
        \\    // Ignore
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .fn_decl_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .fn_decl_block = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
