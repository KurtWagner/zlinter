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

    /// Exclude extern / foreign functions. An extern function refers to a
    /// foreign function — typically defined outside of Zig, such as in a C
    /// library or other system-provided binary. You typically don't want to
    /// enforce naming conventions on these functions.
    exclude_extern: bool = true,

    /// Exclude exported functions. Export makes the symbol visible to
    /// external code, such as C or other languages that might link against
    /// your Zig code. You may prefer to rely on the naming conventions of
    /// the code being linked, in which case, you may set this to true.
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
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;
    var fn_buffer: [1]Ast.Node.Index = undefined;

    var node: NodeIndexShim = .init(1);
    nodes: while (node.index < tree.nodes.len) : (node.index += 1) {
        const fn_proto = fnProto(tree, &fn_buffer, node.toNodeIndex()) orelse continue :nodes;

        if (config.exclude_extern and fn_proto.extern_export_inline_token != null) {
            const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
            if (token_tag == .keyword_extern) continue :nodes;
        }

        if (config.exclude_export and fn_proto.extern_export_inline_token != null) {
            const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
            if (token_tag == .keyword_export) continue :nodes;
        }

        if (fn_proto.ast.params.len <= config.max) continue :nodes;

        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, fn_proto.ast.params[0]),
            .end = .endOfNode(tree, fn_proto.ast.params[fn_proto.ast.params.len - 1]),
            .message = try std.fmt.allocPrint(gpa, "Exceeded maximum positional arguments of {d}.", .{config.max}),
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

inline fn fnProto(tree: Ast, buffer: *[1]Ast.Node.Index, node: Ast.Node.Index) ?Ast.full.FnProto {
    return switch (shims.nodeTag(tree, node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buffer, node),
        .fn_proto_simple => tree.fnProtoSimple(buffer, node),
        else => null,
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
                .message = "Exceeded maximum positional arguments of 1.",
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
                .message = "Exceeded maximum positional arguments of 1.",
            },
        },
    );
}

test "general" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn ok() void {}
        \\fn alsoOk(a1:u32, a2:u32, a3:u32, a4:u32, a5:u32) void {}
        \\fn noOk(a1:u32, a2:u32, a3:u32, a4:u32, a5:u32, a6:u32) void {}
    ,
        .{},
        Config{ .severity = .@"error" },
        &.{
            .{
                .rule_id = "max_positional_args",
                .severity = .@"error",
                .slice = "u32, a2:u32, a3:u32, a4:u32, a5:u32, a6:u32",
                .message = "Exceeded maximum positional arguments of 5.",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
