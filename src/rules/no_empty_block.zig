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
//! Whitespace-only blocks are reported. Blocks containing only comments are
//! treated as documented no-op blocks and are allowed.
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

    /// Severity for empty `test` blocks
    test_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `comptime` blocks
    comptime_block: zlinter.rules.LintProblemSeverity = .@"error",
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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple;

        if (declBlock(tree, node)) |decl_block| {
            const severity = switch (decl_block.kind) {
                .fn_decl => config.fn_decl_block,
                .test_decl => config.test_block,
                .comptime_block => config.comptime_block,
            };
            if (severity != .off and isWhitespaceOnlyBlock(tree, decl_block.block)) {
                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(decl_block.block)),
                    .end = .endOfToken(tree, tree.lastToken(decl_block.block)),
                    .message = try std.fmt.allocPrint(
                        session_arena,
                        problem_msg_template,
                        .{decl_block.kind.name()},
                    ),
                });
            }
            continue :nodes;
        }

        const statement = zlinter.ast.fullStatement(tree, node) orelse continue :nodes;
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

        var block_candidates_buffer: [2]BlockCandidate = undefined;
        var block_candidates: std.ArrayList(BlockCandidate) = .initBuffer(&block_candidates_buffer);

        switch (statement) {
            .@"if" => |info| {
                block_candidates.appendAssumeCapacity(.{ .node = info.ast.then_expr, .label = "if body" });
                if (info.ast.else_expr.unwrap()) |n| {
                    block_candidates.appendAssumeCapacity(.{ .node = n, .label = "if else" });
                }
            },
            .@"while" => |info| {
                block_candidates.appendAssumeCapacity(.{ .node = info.ast.then_expr, .label = "while body" });
                if (info.ast.else_expr.unwrap()) |n| {
                    block_candidates.appendAssumeCapacity(.{ .node = n, .label = "while else" });
                }
            },
            .@"for" => |info| {
                block_candidates.appendAssumeCapacity(.{ .node = info.ast.then_expr, .label = "for body" });
                if (info.ast.else_expr.unwrap()) |n| {
                    block_candidates.appendAssumeCapacity(.{ .node = n, .label = "for else" });
                }
            },
            .switch_case => |info| block_candidates.appendAssumeCapacity(.{ .node = info.ast.target_expr, .label = "switch case" }),
            .@"catch" => |expr_node| block_candidates.appendAssumeCapacity(.{ .node = expr_node, .label = "catch" }),
            .@"defer" => |expr_node| block_candidates.appendAssumeCapacity(.{ .node = expr_node, .label = "defer" }),
            .@"errdefer" => |expr_node| block_candidates.appendAssumeCapacity(.{ .node = expr_node, .label = "errdefer" }),
        }

        block_candidates: for (block_candidates.items) |candidate| {
            const expr_node = candidate.node;

            // Ignore here as it'll be processed in the outer loop.
            if (zlinter.ast.fullStatement(tree, expr_node) != null) continue :block_candidates;

            if (!isWhitespaceOnlyBlock(tree, expr_node)) continue :block_candidates;

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = severity,
                .start = .startOfToken(tree, tree.firstToken(expr_node)),
                .end = .endOfToken(tree, tree.lastToken(expr_node)),
                .message = try std.fmt.allocPrint(
                    session_arena,
                    problem_msg_template,
                    .{candidate.label},
                ),
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

fn isWhitespaceOnlyBlock(tree: Ast, node: Ast.Node.Index) bool {
    const is_block = switch (tree.nodeTag(node)) {
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

    const start = tree.tokenStart(first_token) + tree.tokenSlice(last_token).len;
    const end = tree.tokenStart(last_token);

    // Comments are intentionally treated as documentation, so any non-whitespace
    // byte between braces means the block is allowed.
    for (start..end) |i| {
        if (!std.ascii.isWhitespace(tree.source[i])) {
            return false;
        }
    }
    return true;
}

const DeclBlock = struct {
    block: Ast.Node.Index,
    kind: Kind,

    const Kind = enum {
        fn_decl,
        test_decl,
        comptime_block,

        fn name(self: Kind) []const u8 {
            return switch (self) {
                .fn_decl => "function declaration",
                .test_decl => "test",
                .comptime_block => "comptime",
            };
        }
    };
};

const BlockCandidate = struct {
    node: Ast.Node.Index,
    label: []const u8,
};

fn declBlock(tree: Ast, node: Ast.Node.Index) ?DeclBlock {
    return switch (tree.nodeTag(node)) {
        .fn_decl => .{
            .block = tree.nodeData(node).node_and_node.@"1",
            .kind = .fn_decl,
        },
        .test_decl => .{
            .block = tree.nodeData(node).opt_token_and_node[1],
            .kind = .test_decl,
        },
        .@"comptime" => .{
            .block = tree.nodeData(node).node,
            .kind = .comptime_block,
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
        \\ if (true) {} else {
        \\  // Deliberate
        \\ }
        \\
        \\ if (false) {
        \\  return;
        \\ } else {}
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
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
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
        \\ while (i > 1) {} else {}
        \\
        \\ while (i < 10) : (i += 1) {
        \\   // deliberate
        \\ } else {
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
                    .slice =
                    \\{
                    \\ }
                    ,
                    .message = "Empty while else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty while body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty while else blocks are discouraged. If deliberately empty, include a comment inside the block.",
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
        \\ for (0..1) |_| {} else {}
        \\
        \\ for (0..1) |_| {
        \\  // deliberate
        \\ } else {
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
                    \\ }
                    ,
                    .message = "Empty for else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty for body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty for else blocks are discouraged. If deliberately empty, include a comment inside the block.",
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

test "nested statement bodies" {
    const source =
        \\pub fn main() void {
        \\    const items = [_]u8{1};
        \\    if (true) if (true) {} else {};
        \\    while (true) if (true) {} else {};
        \\    for (items) |_| if (true) {} else {};
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{
                .if_block = severity,
                .while_block = severity,
                .for_block = severity,
            },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }
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

test "test blocks" {
    const source =
        \\test {}
        \\
        \\test "name" {}
        \\
        \\test {
        \\    // deliberate
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .test_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty test blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty test blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .test_block = .off },
        &.{},
    );
}

test "comptime blocks" {
    const source =
        \\comptime {}
        \\
        \\comptime {
        \\    // deliberate
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .comptime_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty comptime blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .comptime_block = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
