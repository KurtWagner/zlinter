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
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_swallow_error),
        .run = &run,
    };
}

/// Runs the no_swallow_error rule.
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

    const root: zlinter.shims.NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const maybe_problem: ?struct {
            severity: zlinter.rules.LintProblemSeverity,
            message: []const u8,
        } = problem: {
            switch (zlinter.shims.nodeTag(tree, node.toNodeIndex())) {
                .@"catch" => {
                    const data = zlinter.shims.nodeData(tree, node.toNodeIndex());
                    const rhs = switch (zlinter.version.zig) {
                        .@"0.14" => data.rhs,
                        .@"0.15" => data.node_and_node.@"1",
                    };

                    switch (zlinter.shims.nodeTag(tree, rhs)) {
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
                    if (zlinter.shims.NodeIndexShim.initOptional(if_info.ast.else_expr)) |else_node| {
                        switch (zlinter.shims.nodeTag(tree, else_node.toNodeIndex())) {
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
            if (config.exclude_tests) {
                var next_parent = connections.parent;
                while (next_parent) |parent| {
                    if (zlinter.shims.nodeTag(tree, parent) == .test_decl) continue :skip;

                    next_parent = doc.lineage.items(.parent)[zlinter.shims.NodeIndexShim.init(parent).index];
                }
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

fn isEmptyOrUnreachableBlock(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) enum { none, empty, @"unreachable" } {
    const tag = zlinter.shims.nodeTag(tree, node);
    std.debug.assert(tag == .block_two or tag == .block_two_semicolon);

    const data = zlinter.shims.nodeData(tree, node);
    const lhs, const rhs = switch (zlinter.version.zig) {
        .@"0.14" => .{
            zlinter.shims.NodeIndexShim.initOptional(data.lhs),
            zlinter.shims.NodeIndexShim.initOptional(data.rhs),
        },
        .@"0.15" => .{
            zlinter.shims.NodeIndexShim.initOptional(data.opt_node_and_opt_node.@"0"),
            zlinter.shims.NodeIndexShim.initOptional(data.opt_node_and_opt_node.@"1"),
        },
    };

    if (lhs == null and rhs == null) return .empty;
    if (lhs != null and zlinter.shims.nodeTag(tree, lhs.?.toNodeIndex()) == .unreachable_literal) return .@"unreachable";
    return .none;
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
