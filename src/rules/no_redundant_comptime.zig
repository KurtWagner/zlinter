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

fn isRedundantComptimeType(tree: Ast, type_expr: Ast.Node.Index) bool {
    if (tree.nodeTag(type_expr) != .identifier) return false;
    const slice = tree.tokenSlice(tree.firstToken(type_expr));
    for (redundant_types) |t| {
        if (std.mem.eql(u8, slice, t)) return true;
    }
    return false;
}

/// Runs the no_redundant_comptime rule.
fn run(
    rule: zlinter.rules.LintRule,
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.tree(context);
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
        while (param_it.next()) |param| {
            const comptime_token = param.comptime_noalias orelse continue;
            if (tree.tokenTag(comptime_token) != .keyword_comptime) continue;

            const type_node = param.type_expr orelse continue;
            if (!isRedundantComptimeType(tree, type_node)) continue;

            const type_slice = tree.tokenSlice(tree.firstToken(type_node));
            try lint_problems.append(gpa, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, comptime_token),
                .end = .endOfToken(tree, tree.lastToken(type_node)),
                .message = try std.fmt.allocPrint(
                    gpa,
                    "Redundant `comptime` on parameter of type `{s}` - parameters of this type are always comptime",
                    .{type_slice},
                ),
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.absPath(context),
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
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
                .slice = "comptime T: type",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
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
                .slice = "comptime a: comptime_int",
                .message = "Redundant `comptime` on parameter of type `comptime_int` - parameters of this type are always comptime",
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime b: comptime_int",
                .message = "Redundant `comptime` on parameter of type `comptime_int` - parameters of this type are always comptime",
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
                .slice = "comptime T: type",
                .message = "Redundant `comptime` on parameter of type `type` - parameters of this type are always comptime",
            },
            .{
                .rule_id = "no_redundant_comptime",
                .severity = .warning,
                .slice = "comptime F: comptime_float",
                .message = "Redundant `comptime` on parameter of type `comptime_float` - parameters of this type are always comptime",
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
