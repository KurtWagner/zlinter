//! Flags redundant `comptime` on parameters whose types are always comptime-known.
//!
//! In Zig, parameters of type `type`, `comptime_int`, and `comptime_float` are always comptime.
//! Writing `comptime T: type` is equivalent to `T: type`.
//!
//! **Good:**
//!
//! ```zig
//! fn List(T: type) type { ... }
//! fn add(a: comptime_int, b: comptime_int) comptime_int { ... }
//! ```
//!
//! **Bad:**
//!
//! ```zig
//! fn List(comptime T: type) type { ... }
//! fn add(comptime a: comptime_int, comptime b: comptime_int) comptime_int { ... }
//! ```
//!
//! `no_redundant_comptime` supports auto fixes with the `--fix` flag.
//! Fixes are not applied when the surrounding layout is comment-adjacent or otherwise ambiguous.
//!

/// Config for no_redundant_comptime rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_redundant_comptime rule.
pub fn buildRule(_: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_redundant_comptime),
        .run = &run,
    };
}

const redundant_types = [_][]const u8{
    "type",
    "comptime_int",
    "comptime_float",
};

fn unwrapParens(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (tree.nodeTag(current) == .grouped_expression)
        current = tree.nodeData(current).node_and_token[0];
    return current;
}

fn isRedundantComptimeType(tree: Ast, type_expr: Ast.Node.Index) bool {
    const unwrapped = unwrapParens(tree, type_expr);
    if (tree.nodeTag(unwrapped) != .identifier) return false;

    const slice = tree.tokenSlice(tree.firstToken(unwrapped));
    for (redundant_types) |t|
        if (std.mem.eql(u8, slice, t)) return true;
    return false;
}

/// Runs the no_redundant_comptime rule.
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

    const tree = doc.tree(session);
    var fn_buffer: [1]Ast.Node.Index = undefined;

    var index: u32 = 1;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);

        const fn_proto = switch (tree.nodeTag(node)) {
            .fn_proto => tree.fnProto(node),
            .fn_proto_multi => tree.fnProtoMulti(node),
            .fn_proto_one => tree.fnProtoOne(&fn_buffer, node),
            .fn_proto_simple => tree.fnProtoSimple(&fn_buffer, node),
            else => null,
        } orelse continue;

        var param_it = fn_proto.iterate(&tree);
        params: while (param_it.next()) |param| {
            const comptime_token = param.comptime_noalias orelse
                continue :params;
            if (tree.tokenTag(comptime_token) != .keyword_comptime)
                continue :params;

            const type_node = param.type_expr orelse continue :params;
            if (!isRedundantComptimeType(tree, type_node))
                continue :params;

            const unwrapped_type_node = unwrapParens(tree, type_node);
            const type_slice = tree.tokenSlice(tree.firstToken(unwrapped_type_node));
            const next_token = param.name_token orelse tree.firstToken(type_node);
            const fix_range = redundantComptimeFixRange(tree.source, tree, comptime_token, next_token);
            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, comptime_token),
                .end = .endOfToken(tree, comptime_token),
                .message = try session_arena.print(
                    "Redundant `comptime` on parameter of type `{s}` - parameters of this type are always comptime",
                    .{type_slice},
                ),
                .fix = if (fix_range) |range| .{
                    .start = range.start,
                    .end = range.end,
                    .text = "",
                } else null,
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

fn redundantComptimeFixRange(
    source: []const u8,
    tree: Ast,
    comptime_token: Ast.TokenIndex,
    next_token: Ast.TokenIndex,
) ?struct { start: usize, end: usize } {
    const start = tree.tokenStart(comptime_token);
    const comptime_end = start + tree.tokenSlice(comptime_token).len;
    const end = tree.tokenStart(next_token);

    if (end <= comptime_end) return null;

    for (source[comptime_end..end]) |c|
        if (!std.ascii.isWhitespace(c)) return null;

    return .{
        .start = start,
        .end = end,
    };
}

test "no_redundant_comptime" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});

    // Bad: redundant comptime on type parameter
    try zlinter.testing.testRunRule(
        rule,
        \\fn List(comptime T: type) type {
        \\    return struct {};
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = .{ .start = 8, .end = 17, .text = "" },
            },
        },
    );

    // Bad: redundant comptime on parenthesized type parameter
    try zlinter.testing.testRunRule(
        rule,
        \\fn List(comptime T: (type)) type {
        \\    return struct {};
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = .{ .start = 8, .end = 17, .text = "" },
            },
        },
    );

    // Bad: redundant comptime on comptime_int
    try zlinter.testing.testRunRule(
        rule,
        \\fn add(comptime a: comptime_int, comptime b: comptime_int) comptime_int {
        \\    return a + b;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_int` - parameters of this type are always comptime",
                .fix = .{ .start = 7, .end = 16, .text = "" },
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_int` - parameters of this type are always comptime",
                .fix = .{ .start = 33, .end = 42, .text = "" },
            },
        },
    );

    // Bad: redundant comptime on parenthesized comptime_int and comptime_float
    try zlinter.testing.testRunRule(
        rule,
        \\fn add(comptime a: (comptime_int), comptime b: (comptime_float)) void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_int` - parameters of this type are always comptime",
                .fix = .{ .start = 7, .end = 16, .text = "" },
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_float` - parameters of this type are always comptime",
                .fix = .{ .start = 35, .end = 44, .text = "" },
            },
        },
    );

    // Bad: redundant comptime on discard parameters
    try zlinter.testing.testRunRule(
        rule,
        \\fn f(comptime _: type) void {}
        \\fn g(comptime _: comptime_int) void {}
        \\fn h(comptime _: comptime_float) void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = .{ .start = 5, .end = 14, .text = "" },
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_int` - parameters of this type are always comptime",
                .fix = .{ .start = 36, .end = 45, .text = "" },
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_float` - parameters of this type are always comptime",
                .fix = .{ .start = 75, .end = 84, .text = "" },
            },
        },
    );

    // Bad: two redundant comptime params separated by a non-comptime param
    try zlinter.testing.testRunRule(
        rule,
        \\fn mixed(comptime T: type, n: usize, comptime F: comptime_float) void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = .{ .start = 9, .end = 18, .text = "" },
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `comptime_float` - parameters of this type are always comptime",
                .fix = .{ .start = 37, .end = 46, .text = "" },
            },
        },
    );

    // Bad: redundant comptime on multiline parameter formatting
    try zlinter.testing.testRunRule(
        rule,
        \\fn List(
        \\    comptime
        \\    T: type,
        \\) type {
        \\    return struct {};
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = .{ .start = 13, .end = 26, .text = "" },
            },
        },
    );

    // Autofix is withheld when comments make the layout ambiguous
    try zlinter.testing.testRunRule(
        rule,
        \\fn List(
        \\    comptime // intentionally weird formatting
        \\    T: type,
        \\) type {
        \\    return struct {};
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = null,
            },
        },
    );

    // Bad: redundant comptime in anonymous function type
    try zlinter.testing.testRunRule(
        rule,
        \\const Callback = fn (comptime T: type) void;
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
                .fix = .{ .start = 21, .end = 30, .text = "" },
            },
        },
    );

    // Good: comptime on @TypeOf (not inherently comptime)
    try zlinter.testing.testRunRule(
        rule,
        \\fn wrap(comptime x: @TypeOf(some_val)) void {}
    ,
        .{},
        Config{},
        &.{},
    );

    // Good: comptime on non-comptime types
    try zlinter.testing.testRunRule(
        rule,
        \\fn foo(comptime n: usize) void {}
        \\fn keep(comptime _: usize) void {}
    ,
        .{},
        Config{},
        &.{},
    );

    // Good: function type alias with non-redundant comptime parameter
    try zlinter.testing.testRunRule(
        rule,
        \\const Callback = fn (comptime n: usize) void;
    ,
        .{},
        Config{},
        &.{},
    );

    // Good: parenthesized non-redundant types
    try zlinter.testing.testRunRule(
        rule,
        \\fn foo(comptime n: (usize)) void {}
        \\fn wrap(comptime x: (@TypeOf(value))) void {}
    ,
        .{},
        Config{},
        &.{},
    );

    // Good: no comptime keyword
    try zlinter.testing.testRunRule(
        rule,
        \\fn List(T: type) type {
        \\    return struct {};
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    // Off severity
    try zlinter.testing.testRunRule(
        rule,
        \\fn List(comptime T: type) type {
        \\    return struct {};
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
