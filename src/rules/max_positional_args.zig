//! Enforces that a function does not define too many positional arguments.
//!
//! Keeping positional argument lists short improves readability and encourages
//! concise designs.
//!
//! If the function is doing too many things, consider splitting it up
//! into smaller more focused functions. Alternatively, accept a struct with
//! appropriate defaults.

/// Config for max_positional_args rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// The max number of positional arguments. Functions with more than this
    /// many arguments will fail the rule.
    max: u8 = 5,

    /// Exclude extern / foreign functions. An extern function signature is
    /// usually dictated by a foreign API, so its parameter count may be fixed
    /// by an external boundary rather than by local code style.
    exclude_extern: bool = true,

    /// Exclude exported functions. Exported signatures may be constrained by
    /// an external ABI or consumer at the call boundary. Project-owned export
    /// APIs can still choose to enforce this rule if they control the shape of
    /// the interface.
    exclude_export: bool = false,
};

/// Builds and returns the max_positional_args rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.max_positional_args),
        .run = &run,
    };
}

/// Runs the max_positional_args rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);
    var fn_buffer: [1]Ast.Node.Index = undefined;

    var index: u32 = 1;
    nodes: while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const fn_proto = fnProto(tree, &fn_buffer, node) orelse continue :nodes;

        if (shouldSkipFnProto(tree, fn_proto, config)) continue :nodes;

        if (fn_proto.ast.params.len <= config.max) continue :nodes;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, firstParamStartToken(tree, fn_proto) orelse tree.firstToken(fn_proto.ast.params[0])),
            .end = .endOfNode(tree, fn_proto.ast.params[fn_proto.ast.params.len - 1]),
            .message = try std.fmt.allocPrint(session_arena, "Exceeded maximum positional arguments of {d}, found {d}.", .{ config.max, fn_proto.ast.params.len }),
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

inline fn fnProto(tree: Ast, buffer: *[1]Ast.Node.Index, node: Ast.Node.Index) ?Ast.full.FnProto {
    return switch (tree.nodeTag(node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buffer, node),
        .fn_proto_simple => tree.fnProtoSimple(buffer, node),
        else => null,
    };
}

fn firstParamStartToken(tree: Ast, fn_proto: Ast.full.FnProto) ?Ast.TokenIndex {
    if (fn_proto.ast.params.len == 0) return null;

    var it = fn_proto.iterate(&tree);
    const first_param = it.next() orelse return null;

    return firstParamStartTokenFromParam(tree, first_param);
}

fn firstParamStartTokenFromParam(tree: Ast, param: Ast.full.FnProto.Param) ?Ast.TokenIndex {
    if (param.comptime_noalias) |token| return token;
    if (param.name_token) |token| return token;
    if (param.anytype_ellipsis3) |token| return token;
    if (param.type_expr) |type_expr| return tree.firstToken(type_expr);
    return null;
}

fn shouldSkipFnProto(tree: Ast, fn_proto: Ast.full.FnProto, config: Config) bool {
    const token = fn_proto.extern_export_inline_token orelse return false;
    const token_tag = tree.tokens.items(.tag)[token];

    return switch (token_tag) {
        .keyword_extern => config.exclude_extern,
        .keyword_export => config.exclude_export,
        .keyword_inline => false,
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "export excluded" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\export fn exportToManyArgs(u32, u32) void;
    ,
        .{},
        Config{ .exclude_export = true, .max = 1 },
        &.{},
    );
}

test "export included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\export fn exportToManyArgs(u32, u32) void;
    ,
        .{},
        Config{ .exclude_export = false, .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .warning,
                .slice = "u32, u32",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "extern excluded" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\extern fn externToManyArgs(u32, u32) void;
    ,
        .{},
        Config{ .exclude_extern = true, .max = 1 },
        &.{},
    );
}

test "extern included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\extern fn externToManyArgs(u32, u32) void;
    ,
        .{},
        Config{ .exclude_extern = false, .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .warning,
                .slice = "u32, u32",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "inline included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\inline fn inlineToManyArgs(u32, u32) void {}
    ,
        .{},
        Config{ .exclude_extern = true, .exclude_export = true, .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .warning,
                .slice = "u32, u32",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "zero parameters are accepted" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn zero() void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 0 },
        &.{},
    );
}

test "one parameter exceeds zero max" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn one(a: u32) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 0 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "a: u32",
                .message = "Exceeded maximum positional arguments of 0, found 1.",
            },
        },
    );
}

test "many parameters exceed low max" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn many(a: u32, b: u32) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "a: u32, b: u32",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "declaration-only prototype is linted" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn declared(a: u32, b: u32) void;
    ,
        .{},
        Config{ .severity = .@"error", .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "a: u32, b: u32",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "multiline named parameters" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn f(
        \\    comptime T: type,
        \\    noalias buf: []u8,
        \\    count: usize
        \\) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice =
                \\comptime T: type,
                \\    noalias buf: []u8,
                \\    count: usize
                ,
                .message = "Exceeded maximum positional arguments of 1, found 3.",
            },
        },
    );
}

test "single line parameters" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn write(noalias buf: []u8, src: []const u8) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "noalias buf: []u8, src: []const u8",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "anytype parameter" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn read(value: anytype, first: u8, second: u8) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 1 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "value: anytype, first: u8, second: u8",
                .message = "Exceeded maximum positional arguments of 1, found 2.",
            },
        },
    );
}

test "exact maximum with modifiers" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn exact(comptime T: type, value: T) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 2 },
        &.{},
    );
}

test "zero max one parameter" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn tooMany(a: u32) void {}
    ,
        .{},
        Config{ .severity = .@"error", .max = 0 },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "a: u32",
                .message = "Exceeded maximum positional arguments of 0, found 1.",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
