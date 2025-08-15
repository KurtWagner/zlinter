//! Disallow using inferred error sets in function return types — always declare them explicitly.
//!
//! In Zig, when you write `!T` as a return type without an explicit error set
//! (e.g. `!void`), Zig infers the error set from whatever operations inside the
//! function can fail.
//!
//! This is powerful, but it can:
//!
//!  - Make APIs harder to understand - the possible errors aren’t visible at the signature.
//!  - Make refactoring risky - adding or changing a failing operation silently changes the function’s error type.
//!  - Lead to brittle dependencies - downstream callers may break if the inferred error set grows or changes.
//!
//! The goal of the rule is to keep error contracts clear and stable. If it can fail, say how.

/// Config for no_inferred_error_unions rule.
pub const Config = struct {
    /// The severity of inferred error unions (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Allow inferred error unions for private functions.
    allow_private: bool = true,

    /// Allow `anyerror` as the explicit error.
    allow_anyerror: bool = true,
};

/// Builds and returns the no_inferred_error_unions rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_inferred_error_unions),
        .run = &run,
    };
}

/// Runs the no_inferred_error_unions rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    var fn_decl_buffer: [1]Ast.Node.Index = undefined;
    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const tag = shims.nodeTag(tree, node.toNodeIndex());
        if (tag != .fn_decl) continue :nodes;

        const fn_decl = tree.fullFnProto(&fn_decl_buffer, node.toNodeIndex()) orelse continue :nodes;
        if (config.allow_private and isFnPrivate(tree, fn_decl)) continue :nodes;

        const return_type = NodeIndexShim.initOptional(fn_decl.ast.return_type) orelse continue :nodes;

        const return_type_tag = shims.nodeTag(tree, return_type.toNodeIndex());
        switch (return_type_tag) {
            .error_union => if (config.allow_anyerror or
                !std.mem.eql(u8, tree.tokenSlice(tree.firstToken(return_type.toNodeIndex())), "anyerror"))
                continue :nodes,
            .identifier => switch (tree.tokens.items(.tag)[tree.firstToken(return_type.toNodeIndex()) - 1]) {
                .bang => {},
                else => continue :nodes,
            },
            else => continue :nodes,
        }

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, tree.firstToken(node.toNodeIndex())),
            .end = .endOfNode(tree, return_type.toNodeIndex()),
            .message = try allocator.dupe(u8, "Function returns an inferred error union. Prefer an explicit error set"),
        });
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

fn isFnPrivate(tree: Ast, fn_decl: Ast.full.FnProto) bool {
    const visibility_token = fn_decl.visib_token orelse return true;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => false,
        else => true,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "no_inferred_error_unions - valid function declarations" {
    inline for (&.{
        \\pub fn pubGood() error{Always}!void {
        \\  return error.Always;
        \\}
        ,
        \\const Errors = error{Always};
        \\pub fn pubGood() Errors!void {
        \\  return error.Always;
        \\}
        ,
        \\pub fn pubAlsoAllowedByDefault() anyerror!void {
        \\return error.Always;
        \\}
        ,
        \\pub fn hasNoError() void {}
        ,
        \\fn privateAllowInferred() !void {
        \\ return error.Always;
        \\}
    }) |source| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{},
            &.{},
        );
    }
}

test "no_inferred_error_unions - Invalid function declarations - off" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn inferred() !void {
        \\  return error.Always;
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

test "no_inferred_error_unions - Invalid function declarations - defaults" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn inferred() !void {
        \\  return error.Always;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "pub fn inferred() !void ",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
    );
}

test "no_inferred_error_unions - Invalid function declarations - allow_private = false" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn inferred() !void {
        \\  return error.Always;
        \\}
    ,
        .{},
        Config{ .allow_private = false },
        &.{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "fn inferred() !void ",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
    );
}

test "no_inferred_error_unions - Invalid function declarations - allow_anyerror = false" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn inferred() anyerror!void {
        \\  return error.Always;
        \\}
    ,
        .{},
        Config{ .allow_anyerror = false, .severity = .@"error" },
        &.{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .@"error",
                .slice = "pub fn inferred() anyerror!void ",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
