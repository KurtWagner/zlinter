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
        .run = &run,
    };
}

/// Runs the require_labeled_continue rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (tree.nodeTag(node.toNodeIndex()) != .@"continue") continue;

        if (hasContinueLabel(tree, node.toNodeIndex())) continue;

        const depth = loopDepth(doc, node.toNodeIndex());
        if (depth <= config.max_unlabeled_depth) continue;

        const continue_token = tree.nodeMainToken(node.toNodeIndex());
        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, continue_token),
            .end = .endOfToken(tree, continue_token),
            .message = try gpa.dupe(
                u8,
                "Unlabeled `continue` inside nested loop is ambiguous. Use a loop label to make the control flow explicit.",
            ),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

fn loopDepth(doc: *const zlinter.session.LintDocument, node: Ast.Node.Index) u32 {
    var depth: u32 = 0;
    var it = doc.nodeAncestorIterator(node);
    while (it.next()) |ancestor| {
        if (NodeIndexShim.init(ancestor).isRoot()) break;
        if (isLoopNode(doc.handle.tree, ancestor)) depth += 1;
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
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
