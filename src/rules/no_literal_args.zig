//! Disallow passing primitive literal numbers and booleans directly as function arguments.
//!
//! Passing literal `1`, `0`, `true`, or `false` directly to a function is ambiguous.
//!
//! These magic literals don’t explain what they mean. Consider using named constants or if you're the owner of the API and there's multiple arguments, consider introducing a struct argument

/// Config for no_literal_args rule.
pub const Config = struct {
    /// The severity of detecting char literals (off, warning, error).
    detect_char_literal: zlinter.rules.LintProblemSeverity = .off,

    // TODO: Perhaps this should be smart enough to ignore "fmt" param names? It's off by default for now anyway.
    /// The severity of detecting string literals (off, warning, error).
    detect_string_literal: zlinter.rules.LintProblemSeverity = .off,

    /// The severity of detecting number literals (off, warning, error).
    detect_number_literal: zlinter.rules.LintProblemSeverity = .off,

    /// The severity of detecting bool literals (off, warning, error).
    detect_bool_literal: zlinter.rules.LintProblemSeverity = .warning,

    /// Skip if found within `test { ... }` block.
    exclude_tests: bool = true,

    /// Skip if the literal argument is to a function with given name (case-sensitive).
    exclude_fn_names: []const []const u8 = &.{
        "print",
        "alloc",
        "allocWithOptions",
        "allocWithOptionsRetAddr",
        "allocSentinel",
        "alignedAlloc",
        "allocAdvancedWithRetAddr",
        "resize",
        "realloc",
        "reallocAdvanced",
        "parseInt",
        "IntFittingRange",
    },
};

/// Builds and returns the no_literal_args rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_literal_args),
        .run = &run,
    };
}

const LiteralKind = enum { bool, string, number, char };

/// Runs the no_literal_args rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;
    var call_buffer: [1]Ast.Node.Index = undefined;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const call = tree.fullCall(&call_buffer, node.toNodeIndex()) orelse continue :nodes;

        for (call.ast.params) |param_node| {
            const kind: LiteralKind = switch (shims.nodeTag(tree, param_node)) {
                .number_literal => .number,
                .string_literal, .multiline_string_literal => .string,
                .char_literal => .char,
                .identifier => switch (tree.tokens.items(.tag)[shims.nodeMainToken(tree, param_node)]) {
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

            // if configured, skip if a parent is a test block
            if (config.exclude_tests and doc.isEnclosedInTestBlock(node)) {
                continue :nodes;
            }

            const fn_name = tree.tokenSlice(tree.lastToken(call.ast.fn_expr));
            for (config.exclude_fn_names) |exclude_fn_name| {
                if (std.mem.eql(u8, exclude_fn_name, fn_name)) continue :nodes;
            }

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
        try zlinter.results.LintResult.init(
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

test "no_literal_args" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  const num = 10;
        \\  const flag = false;
        \\  call(true, 0, num, 0.5, flag, false);
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                // TODO: Split this into different tests to ensure severity doesn't leak between
                .detect_number_literal = severity,
                .detect_bool_literal = severity,
                .detect_char_literal = severity,
                .detect_string_literal = severity,
            },
            &.{
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "true,",
                    .message = "Avoid bool literal arguments as they're ambiguous.",
                },
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "0,",
                    .message = "Avoid number literal arguments as they're ambiguous.",
                },
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "0.5,",
                    .message = "Avoid number literal arguments as they're ambiguous.",
                },
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "false)",
                    .message = "Avoid bool literal arguments as they're ambiguous.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .off,
            .detect_bool_literal = .off,
            .detect_char_literal = .off,
            .detect_string_literal = .off,
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
