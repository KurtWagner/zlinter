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

    /// The max number of positional arguments. Functions with more than this many arguments will fail the rule.
    max: u8 = 5,
};

/// Builds and returns the max_positional_args rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.max_positional_args),
        .run = &run,
    };
}

/// Runs the max_positional_args rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;

    var node: zlinter.shims.NodeIndexShim = .init(1);
    while (node.index < tree.nodes.len) : (node.index += 1) {
        const fn_proto = fnProto(tree, &fn_buffer, node.toNodeIndex()) orelse continue;
        if (fn_proto.ast.params.len <= config.max) continue;

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, fn_proto.ast.params[0]),
            .end = .endOfNode(tree, fn_proto.ast.params[fn_proto.ast.params.len - 1]),
            .message = try std.fmt.allocPrint(allocator, "Exceeded maximum positional arguments of {d}.", .{config.max}),
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

inline fn fnProto(tree: std.zig.Ast, buffer: *[1]std.zig.Ast.Node.Index, node: std.zig.Ast.Node.Index) ?std.zig.Ast.full.FnProto {
    return switch (zlinter.shims.nodeTag(tree, node)) {
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

const std = @import("std");
const zlinter = @import("zlinter");
