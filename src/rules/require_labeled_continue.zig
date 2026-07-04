//! Enforces explicit loop labels for `continue` statements beyond an allowed loop depth.
//!
//! Unlabeled `continue` is allowed only when loop depth does not exceed the configured maximum.

/// Config for require_labeled_continue rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",

    /// Maximum allowed loop depth for unlabeled `continue`.
    /// Depth 0 means all `continue` statements must be labeled.
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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (tree.nodeTag(node) != .@"continue") continue;

        if (hasContinueLabel(tree, node)) continue;

        const depth = loopDepthInCurrentControlFlow(doc, tree, node);
        if (depth <= config.max_unlabeled_depth) continue;

        const continue_token = tree.nodeMainToken(node);
        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, continue_token),
            .end = .endOfToken(tree, continue_token),
            .message = try session_arena.dupe(
                u8,
                "Unlabeled `continue` exceeds the configured allowed loop depth. Use a loop label to make the control flow explicit.",
            ),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

fn loopDepthInCurrentControlFlow(doc: *const zlinter.session.LintDocument, tree: Ast, node: Ast.Node.Index) u32 {
    var depth: u32 = 0;
    var it = doc.nodeAncestorIterator(node);
    while (it.next()) |ancestor| {
        if (ancestor == .root) break;
        if (isControlFlowBoundary(tree, ancestor)) break;
        if (isLoopNode(tree, ancestor)) depth += 1;
    }
    return depth;
}

fn isControlFlowBoundary(tree: Ast, node: Ast.Node.Index) bool {
    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node) != null)
        return true;

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node) != null)
        return true;

    return false;
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

const expected_nested_continue = [_]zlinter.testing.LintProblemExpectation{.{
    .rule_id = "require_labeled_continue",
    .severity = .@"error",
    .slice = "continue",
    .message = "Unlabeled `continue` exceeds the configured allowed loop depth. Use a loop label to make the control flow explicit.",
}};

test "require_labeled_continue allows unlabeled continue in a single while loop" {
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
}

test "require_labeled_continue reports unlabeled continue in nested while loops" {
    const rule = buildRule(.{});

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
        &expected_nested_continue,
    );
}

test "require_labeled_continue allows labeled continue in nested while loops" {
    const rule = buildRule(.{});

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
}

test "require_labeled_continue respects configured maximum unlabeled loop depth" {
    const rule = buildRule(.{});

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

test "require_labeled_continue reports single-loop continue when maximum unlabeled depth is zero" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    while (true) {
        \\        continue;
        \\    }
        \\}
    ,
        .{},
        Config{ .max_unlabeled_depth = 0 },
        &expected_nested_continue,
    );
}

test "require_labeled_continue does not count loops across function boundaries" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    while (true) {
        \\        const S = struct {
        \\            fn f() void {
        \\                while (true) {
        \\                    continue;
        \\                }
        \\            }
        \\        };
        \\        _ = S;
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "require_labeled_continue reports nested loops inside nested function boundary" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    while (true) {
        \\        const S = struct {
        \\            fn f() void {
        \\                while (true) {
        \\                    while (true) {
        \\                        continue;
        \\                    }
        \\                }
        \\            }
        \\        };
        \\        _ = S;
        \\    }
        \\}
    ,
        .{},
        Config{},
        &expected_nested_continue,
    );
}

test "require_labeled_continue reports unlabeled continue in nested for loops" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    const items = [_]u8{ 1, 2, 3 };
        \\    for (items) |_| {
        \\        for (items) |_| {
        \\            continue;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &expected_nested_continue,
    );
}

test "require_labeled_continue reports unlabeled continue in mixed for and while loops" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    const items = [_]u8{ 1, 2, 3 };
        \\    for (items) |_| {
        \\        while (true) {
        \\            continue;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &expected_nested_continue,
    );
}

test "require_labeled_continue reports unlabeled continue in while loop with continue expression" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    var i: usize = 0;
        \\    while (i < 10) : (i += 1) {
        \\        while (i < 10) {
        \\            continue;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &expected_nested_continue,
    );
}

test "require_labeled_continue allows labeled continue in nested for loops" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    const items = [_]u8{ 1, 2, 3 };
        \\    outer: for (items) |_| {
        \\        for (items) |_| {
        \\            continue :outer;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "require_labeled_continue allows labeled continue in mixed for and while loops" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    const items = [_]u8{ 1, 2, 3 };
        \\    outer: for (items) |_| {
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
}

test "require_labeled_continue allows labeled continue in while loop with continue expression" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    var i: usize = 0;
        \\    outer: while (i < 10) : (i += 1) {
        \\        while (i < 10) {
        \\            continue :outer;
        \\        }
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
