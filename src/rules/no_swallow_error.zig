//! Disallow silently swallowing errors without proper handling or logging.
//!
//! For example, `catch {}` and `catch unreachable`

/// Config for no_swallow_error rule.
pub const Config = struct {
    /// The severity of detecting `catch unreachable` or `catch { unreachable; } (off, warning, error).
    detect_catch_unreachable: zlinter.rules.LintProblemSeverity = .warning,

    /// The severity of detecting `catch {}` (off, warning, error).
    detect_empty_catch: zlinter.rules.LintProblemSeverity = .warning,

    /// The severity of detecting `else |_| {}` (off, warning, error).
    detect_empty_else: zlinter.rules.LintProblemSeverity = .warning,

    /// The severity of detecting `else |_| unreachable` or `else |_| { unreachable; }` (off, warning, error).
    detect_else_unreachable: zlinter.rules.LintProblemSeverity = .warning,

    /// Skip if found within `test { ... }` block.
    exclude_tests: bool = true,
};

/// Builds and returns the no_swallow_error rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_swallow_error),
        .run = &run,
    };
}

/// Runs the no_swallow_error rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const maybe_problem: ?struct {
            severity: zlinter.rules.LintProblemSeverity,
            message: []const u8,
        } = problem: {
            switch (shims.nodeTag(tree, node.toNodeIndex())) {
                .@"catch" => {
                    const data = shims.nodeData(tree, node.toNodeIndex());
                    const rhs = switch (zlinter.version.zig) {
                        .@"0.14" => data.rhs,
                        .@"0.15", .@"0.16" => data.node_and_node.@"1",
                    };

                    switch (shims.nodeTag(tree, rhs)) {
                        .unreachable_literal => if (config.detect_catch_unreachable != .off)
                            break :problem .{
                                .severity = config.detect_catch_unreachable,
                                .message = "Avoid swallowing error with catch unreachable",
                            },
                        .block_two, .block_two_semicolon => switch (isEmptyOrUnreachableBlock(tree, rhs)) {
                            .@"unreachable" => if (config.detect_catch_unreachable != .off)
                                break :problem .{
                                    .severity = config.detect_catch_unreachable,
                                    .message = "Avoid swallowing error with catch unreachable",
                                },
                            .empty => if (config.detect_empty_catch != .off)
                                break :problem .{
                                    .severity = config.detect_empty_catch,
                                    .message = "Avoid swallowing error with empty catch",
                                },
                            .none => {},
                        },
                        else => {},
                    }
                },
                else => if (tree.fullIf(node.toNodeIndex())) |if_info| {
                    if (NodeIndexShim.initOptional(if_info.ast.else_expr)) |else_node| {
                        switch (shims.nodeTag(tree, else_node.toNodeIndex())) {
                            .unreachable_literal => if (config.detect_else_unreachable != .off)
                                break :problem .{
                                    .severity = config.detect_else_unreachable,
                                    .message = "Avoid swallowing error with else unreachable",
                                },
                            .block_two, .block_two_semicolon => switch (isEmptyOrUnreachableBlock(tree, else_node.toNodeIndex())) {
                                .@"unreachable" => if (config.detect_else_unreachable != .off)
                                    break :problem .{
                                        .severity = config.detect_else_unreachable,
                                        .message = "Avoid swallowing error with else unreachable",
                                    },
                                .empty => if (config.detect_empty_else != .off)
                                    break :problem .{
                                        .severity = config.detect_empty_else,
                                        .message = "Avoid swallowing error with empty else",
                                    },
                                .none => {},
                            },
                            else => {},
                        }
                    }
                },
            }
            break :problem null;
        };

        if (maybe_problem) |problem| {
            // if configured, skip if a parent is a test block
            if (config.exclude_tests and doc.isEnclosedInTestBlock(node)) {
                continue :nodes;
            }

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = problem.severity,
                .start = .startOfNode(tree, node.toNodeIndex()),
                .end = .endOfNode(tree, node.toNodeIndex()),
                .message = try allocator.dupe(u8, problem.message),
            });
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

fn isEmptyOrUnreachableBlock(tree: Ast, node: Ast.Node.Index) enum { none, empty, @"unreachable" } {
    const tag = shims.nodeTag(tree, node);
    std.debug.assert(tag == .block_two or tag == .block_two_semicolon);

    const data = shims.nodeData(tree, node);
    const lhs, const rhs = switch (zlinter.version.zig) {
        .@"0.14" => .{
            NodeIndexShim.initOptional(data.lhs),
            NodeIndexShim.initOptional(data.rhs),
        },
        .@"0.15", .@"0.16" => .{
            NodeIndexShim.initOptional(data.opt_node_and_opt_node.@"0"),
            NodeIndexShim.initOptional(data.opt_node_and_opt_node.@"1"),
        },
    };

    if (lhs == null and rhs == null) return .empty;
    if (lhs != null and shims.nodeTag(tree, lhs.?.toNodeIndex()) == .unreachable_literal) return .@"unreachable";
    return .none;
}

test {
    std.testing.refAllDecls(@This());
}

test "no_swallow_error" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() !void {
        \\  method() catch {};
        \\  method() catch unreachable;
        \\  method() catch { unreachable; };
        \\  if (method()) {} else |_| unreachable;
        \\  if (method()) {} else |_| { unreachable; }
        \\  if (method()) {} else |_| {}
        \\  try method();
        \\  if (method()) {} else |e| { std.log.err("{s}", @errorName(e)); } 
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                // TODO: Split these into separate tests to ensure severity isn't leaked
                .detect_catch_unreachable = severity,
                .detect_empty_catch = severity,
                .detect_empty_else = severity,
                .detect_else_unreachable = severity,
            },
            &.{
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| {}",
                    .message = "Avoid swallowing error with empty else",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| { unreachable; }",
                    .message = "Avoid swallowing error with else unreachable",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| unreachable",
                    .message = "Avoid swallowing error with else unreachable",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch { unreachable; }",
                    .message = "Avoid swallowing error with catch unreachable",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch unreachable",
                    .message = "Avoid swallowing error with catch unreachable",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch {}",
                    .message = "Avoid swallowing error with empty catch",
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
            .detect_catch_unreachable = .off,
            .detect_empty_catch = .off,
            .detect_empty_else = .off,
            .detect_else_unreachable = .off,
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
