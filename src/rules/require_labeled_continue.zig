//! Enforces explicit loop labels for `continue` statements in nested loops.
//!
//! Unlabeled `continue` is allowed only when loop depth is exactly 1.

/// Config for require_labeled_continue rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",

    /// Maximum allowed loop depth for unlabeled `continue`.
    /// Depth 1 means a single enclosing loop.
    /// Default 1 allows unlabeled `continue` only at depth 1.
    max_unlabeled_depth: u32 = 1,
};

/// Builds and returns the require_labeled_continue rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_labeled_continue),
        .execution = .syntax_only,
        .run = &run,
    };
}

/// Runs the require_labeled_continue rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;
    const session_arena = session.runtime.sessionArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(session_arena);

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, session_arena);
    defer it.deinit();

    while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (tree.nodeTag(node) != .@"continue") continue;

        if (hasContinueLabel(tree, node)) continue;

        const depth = loopDepth(doc, tree, node);
        if (depth <= config.max_unlabeled_depth) continue;

        const continue_token = tree.nodeMainToken(node);
        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, continue_token),
            .end = .endOfToken(tree, continue_token),
            .message = try session_arena.dupe(
                u8,
                "Unlabeled `continue` inside nested loop is ambiguous. Use a loop label to make the control flow explicit.",
            ),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            try lint_problems.toOwnedSlice(session_arena),
        )
    else
        null;
}

fn loopDepth(doc: *const zlinter.session.LintDocument, tree: Ast, node: Ast.Node.Index) u32 {
    var depth: u32 = 0;
    var it = doc.nodeAncestorIterator(node);
    while (it.next()) |ancestor| {
        if (ancestor == .root) break;
        if (isLoopNode(tree, ancestor)) depth += 1;
    }
    return depth;
}

fn isLoopNode(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .@"while",
        .while_simple,
        .while_cont,
        .@"for",
        .for_simple,
        => true,
        else => false,
    };
}

fn hasContinueLabel(tree: Ast, node: Ast.Node.Index) bool {
    const opt_label, _ = tree.nodeData(node).opt_token_and_opt_node;
    return optionalTokenPresent(opt_label);
}

fn optionalTokenPresent(opt_token: anytype) bool {
    return switch (@typeInfo(@TypeOf(opt_token))) {
        .@"enum" => if (std.meta.hasFn(@TypeOf(opt_token), "unwrap"))
            opt_token.unwrap() != null
        else
            @intFromEnum(opt_token) != 0,
        .optional => opt_token != null,
        else => opt_token != 0,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "require_labeled_continue" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    while (true) {
        \\        if (true) continue;
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    while (true) {
        \\        while (true) {
        \\            continue;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_labeled_continue",
                .severity = .@"error",
                .slice = "continue",
                .message = "Unlabeled `continue` inside nested loop is ambiguous. Use a loop label to make the control flow explicit.",
            },
        },
    );

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    outer: while (true) {
        \\        while (true) {
        \\            continue :outer;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    while (true) {
        \\        while (true) {
        \\            continue;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{ .max_unlabeled_depth = 2 },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
