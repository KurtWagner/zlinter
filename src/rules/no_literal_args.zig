//! Disallow passing primitive literal numbers and booleans directly as function arguments.
//!
//! Passing literal `1`, `0`, `true`, or `false` directly to a function is ambiguous.
//!
//! These magic literals don’t explain what they mean. Consider using named constants or if you're the owner of the API and there's multiple arguments, consider introducing a struct argument

/// Config for no_literal_args rule.
pub const Config = struct {
    /// The severity of detecting char literals (off, warning, error).
    detect_char_literal: zlinter.LintProblemSeverity = .off,

    // TODO: Perhaps this should be smart enough to ignore "fmt" param names? It's off by default for now anyway.
    /// The severity of detecting string literals (off, warning, error).
    detect_string_literal: zlinter.LintProblemSeverity = .off,

    /// The severity of detecting number literals (off, warning, error).
    detect_number_literal: zlinter.LintProblemSeverity = .warning,

    /// The severity of detecting bool literals (off, warning, error).
    detect_bool_literal: zlinter.LintProblemSeverity = .warning,
};

/// Builds and returns the no_literal_args rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.no_literal_args),
        .run = &run,
    };
}

const LiteralKind = enum { bool, string, number, char };

/// Runs the no_literal_args rule.
fn run(
    rule: zlinter.LintRule,
    _: zlinter.LintContext,
    doc: zlinter.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.LintOptions,
) error{OutOfMemory}!?zlinter.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;
    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;

    var node: zlinter.shims.NodeIndexShim = .init(1);
    while (node.index < tree.nodes.len) : (node.index += 1) {
        const call = tree.fullCall(&call_buffer, node.toNodeIndex()) orelse continue;

        for (call.ast.params) |param_node| {
            const kind: LiteralKind = switch (zlinter.shims.nodeTag(tree, param_node)) {
                .number_literal => .number,
                .string_literal, .multiline_string_literal => .string,
                .char_literal => .char,
                .identifier => switch (tree.tokens.items(.tag)[zlinter.shims.nodeMainToken(tree, param_node)]) {
                    .string_literal, .multiline_string_literal_line => .string,
                    .char_literal => .char,
                    .number_literal => .number,
                    else => @as(?LiteralKind, maybe_bool: {
                        const slice = tree.getNodeSource(param_node);
                        break :maybe_bool if (std.mem.eql(u8, slice, "false") or std.mem.eql(u8, slice, "true"))
                            .bool
                        else
                            null;
                    }),
                },
                else => null,
            } orelse continue;

            switch (kind) {
                .bool => if (config.detect_bool_literal != .off)
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_bool_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try std.fmt.allocPrint(allocator, "Avoid bool literal arguments as they're ambiguous.", .{}),
                    }),
                .string => if (config.detect_string_literal != .off)
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_string_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try std.fmt.allocPrint(allocator, "Avoid string literal arguments as they're ambiguous.", .{}),
                    }),
                .char => if (config.detect_char_literal != .off)
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_char_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try std.fmt.allocPrint(allocator, "Avoid char literal arguments as they're ambiguous.", .{}),
                    }),
                .number => if (config.detect_number_literal != .off)
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_number_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try std.fmt.allocPrint(allocator, "Avoid number literal arguments as they're ambiguous.", .{}),
                    }),
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
