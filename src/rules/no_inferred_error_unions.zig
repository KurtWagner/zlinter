//! Disallow using inferred error sets in function return types — always declare them explicitly.
//!
//! In Zig, when you write `!T` as a return type without an explicit error set
//! (e.g. `!void`), Zig infers the error set from whatever operations inside the
//! function can fail.
//!
//! This is powerful, but it can:
//!
//! * Make APIs harder to understand - the possible errors aren’t visible at the signature.
//! * Make refactoring risky - adding or changing a failing operation silently changes the function’s error type.
//! * Lead to brittle dependencies - downstream callers may break if the inferred error set grows or changes.
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

const ReturnProblem = enum {
    inferred_error_union,
    anyerror_error_union,
};

/// Builds and returns the no_inferred_error_unions rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_inferred_error_unions),
        .run = &run,
    };
}

fn isInferredErrorUnionReturn(tree: Ast, return_type: Ast.Node.Index) bool {
    const first = tree.firstToken(return_type);
    if (first == 0) return false;
    return tree.tokens.items(.tag)[first - 1] == .bang;
}

fn classifyReturnProblem(
    tree: Ast,
    return_type: Ast.Node.Index,
    config: Config,
) ?ReturnProblem {
    if (tree.nodeTag(return_type) == .error_union) {
        if (config.allow_anyerror or
            !std.mem.eql(u8, tree.tokenSlice(tree.firstToken(return_type)), "anyerror"))
            return null;

        return .anyerror_error_union;
    }

    if (!isInferredErrorUnionReturn(tree, return_type))
        return null;
    return .inferred_error_union;
}

/// Runs the no_inferred_error_unions rule.
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

    var fn_decl_buffer: [1]Ast.Node.Index = undefined;
    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const tag = tree.nodeTag(node);
        if (tag != .fn_decl) continue :nodes;

        const fn_decl = tree.fullFnProto(&fn_decl_buffer, node) orelse
            continue :nodes;
        if (config.allow_private and zlinter.ast.fnProtoVisibility(tree, fn_decl) == .private)
            continue :nodes;

        const return_type = fn_decl.ast.return_type.unwrap() orelse
            continue :nodes;

        const problem = classifyReturnProblem(tree, return_type, config) orelse {
            continue :nodes;
        };

        const message = switch (problem) {
            .inferred_error_union => "Function returns an inferred error union. Prefer an explicit error set",
            .anyerror_error_union => "Function returns anyerror. Prefer a specific error set",
        };

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = switch (problem) {
                .inferred_error_union => .startOfToken(tree, tree.firstToken(return_type) - 1),
                .anyerror_error_union => .startOfNode(tree, return_type),
            },
            .end = .endOfNode(tree, return_type),
            .message = try session_arena.dupe(u8, message),
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
        \\pub fn pubGoodBytes() error{Always}![]const u8 {
        \\  return error.Always;
        \\}
        ,
        \\pub fn pubGoodMaybePtr() Errors!?*Thing {
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
    }) |source|
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{},
            &.{},
        );
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
                .slice = "!void",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
    );
}

test "no_inferred_error_unions - Invalid function declarations - complex payloads" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const Thing = struct {};
        \\pub fn bytes() ![]const u8 {
        \\  return error.Always;
        \\}
        \\pub fn maybePtr() !?*Thing {
        \\  return error.Always;
        \\}
        \\pub fn ptr() !*Thing {
        \\  return error.Always;
        \\}
        \\pub fn array() ![4]u8 {
        \\  return error.Always;
        \\}
        \\pub fn namespaced() !std.ArrayList(u8) {
        \\  return error.Always;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "!std.ArrayList(u8)",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "![4]u8",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "!*Thing",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "!?*Thing",
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .slice = "![]const u8",
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
                .slice = "!void",
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
                .slice = "anyerror!void",
                .message = "Function returns anyerror. Prefer a specific error set",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
