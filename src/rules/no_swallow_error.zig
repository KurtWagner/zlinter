//! Disallow silently swallowing errors without proper handling or logging.
//!
//! For example, `catch {}` and `catch unreachable`
//!
//! By default the rule will ignore empty blocks that contain a comment. For
//! example,
//!
//! ```zig
//! doSomething() catch {
//!    // Ignored
//! };
//! ```
//!
//! This is because typically in this siutation it's safe to assume the author
//! has put some thought into it being swallowed. This can be disabled by
//! setting `.exclude_comments = false`

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

    /// Whether or not a comment within a block is counted to whether it is empty
    /// or not. A comment usually indicates the author has put some thought
    /// into swallowing an error. e.g., `// Ignored.`.
    exclude_comments: bool = true,
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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    if (config.detect_catch_unreachable == .off and
        config.detect_empty_catch == .off and
        config.detect_empty_else == .off and
        config.detect_else_unreachable == .off)
    {
        return null;
    }

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const maybe_problem: ?struct {
            severity: zlinter.rules.LintProblemSeverity,
            message: []const u8,
        } = problem: {
            switch (tree.nodeTag(node)) {
                .@"catch" => {
                    const data = tree.nodeData(node);
                    const rhs = unwrapGroupedExpr(tree, data.node_and_node.@"1");

                    switch (tree.nodeTag(rhs)) {
                        .unreachable_literal => if (config.detect_catch_unreachable != .off)
                            break :problem .{
                                .severity = config.detect_catch_unreachable,
                                .message = "Avoid swallowing error with catch unreachable",
                            },
                        .block_two, .block_two_semicolon, .block, .block_semicolon => switch (classifyBlock(tree, rhs)) {
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
                            .empty_with_comment => if (config.detect_empty_catch != .off and !config.exclude_comments)
                                break :problem .{
                                    .severity = config.detect_empty_catch,
                                    .message = "Avoid swallowing error with empty catch",
                                },
                            .none => {},
                        },
                        else => {},
                    }
                },
                else => if (tree.fullIf(node)) |if_info| {
                    if (if_info.error_token == null) {
                        continue :nodes;
                    }

                    if (if_info.ast.else_expr.unwrap()) |else_node| {
                        const unwrapped_else = unwrapGroupedExpr(tree, else_node);

                        switch (tree.nodeTag(unwrapped_else)) {
                            .unreachable_literal => if (config.detect_else_unreachable != .off)
                                break :problem .{
                                    .severity = config.detect_else_unreachable,
                                    .message = "Avoid swallowing error with else unreachable",
                                },
                            .block_two, .block_two_semicolon, .block, .block_semicolon => switch (classifyBlock(tree, unwrapped_else)) {
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
                                .empty_with_comment => if (config.detect_empty_else != .off and !config.exclude_comments)
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
            if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) {
                continue :nodes;
            }

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = problem.severity,
                .start = .startOfNode(tree, node),
                .end = .endOfNode(tree, node),
                .message = try session_arena.dupe(u8, problem.message),
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

const BlockClassification = enum {
    none,
    empty,
    empty_with_comment,
    @"unreachable",
};

fn classifyBlock(tree: Ast, node: Ast.Node.Index) BlockClassification {
    return switch (tree.nodeTag(node)) {
        .block_two, .block_two_semicolon => classifyBlockTwo(tree, node),
        .block, .block_semicolon => classifyBlockSpan(tree, node),
        else => .none,
    };
}

fn classifyBlockTwo(tree: Ast, node: Ast.Node.Index) BlockClassification {
    const data = tree.nodeData(node);
    const lhs = data.opt_node_and_opt_node.@"0".unwrap();
    const rhs = data.opt_node_and_opt_node.@"1".unwrap();

    if (lhs == null and rhs == null) {
        return if (emptyBlockContainsLineComment(tree, node))
            .empty_with_comment
        else
            .empty;
    }
    if (lhs) |lhs_node| {
        if (rhs == null and tree.nodeTag(lhs_node) == .unreachable_literal)
            return .@"unreachable";
    }
    return .none;
}

fn classifyBlockSpan(tree: Ast, node: Ast.Node.Index) BlockClassification {
    var buffer: [2]Ast.Node.Index = undefined;
    const statements = tree.blockStatements(&buffer, node) orelse return .none;

    if (statements.len == 0)
        return if (emptyBlockContainsLineComment(tree, node))
            .empty_with_comment
        else
            .empty;

    if (statements.len == 1 and tree.nodeTag(statements[0]) == .unreachable_literal)
        return .@"unreachable";

    return .none;
}

fn unwrapGroupedExpr(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (tree.nodeTag(current) == .grouped_expression)
        current = tree.nodeData(current).node_and_token[0];
    return current;
}

fn emptyBlockContainsLineComment(tree: Ast, node: Ast.Node.Index) bool {
    // This targets just empty blocks and cannot be used generally as it
    // will have false positive. e.g., `const url = "http://ziglang.org"`. As
    // it's just targetted for our empty rule case it should be fine...
    const source = tree.getNodeSource(node);
    return std.mem.find(u8, source, "//") != null;
}

test {
    std.testing.refAllDecls(@This());
}

test "no_swallow_error" {
    const no_swallow_error_source: [:0]const u8 =
        \\pub fn ordinaryControlFlow(cond: bool) void {
        \\  if (cond) {} else {}
        \\  if (cond) {} else unreachable;
        \\}
        \\
        \\pub fn main() !void {
        \\  method() catch {};
        \\  method() catch unreachable;
        \\  method() catch { unreachable; };
        \\  method() catch (unreachable);
        \\  method() catch ({});
        \\  method() catch ({ unreachable; });
        \\  if (method()) {} else |_| unreachable;
        \\  if (method()) {} else |_| { unreachable; }
        \\  if (method()) {} else |_| {}
        \\  if (method()) {} else |_| (unreachable);
        \\  if (method()) {} else |_| ({});
        \\  if (method()) {} else |_| ({ unreachable; });
        \\  method() catch {
        \\    std.log.err("handled", .{});
        \\    std.log.err("handled again", .{});
        \\  };
        \\  if (method()) {} else |_| {
        \\    std.log.err("handled", .{});
        \\    std.log.err("handled again", .{});
        \\  }
        \\  try method();
        \\  if (method()) {} else |e| { std.log.err("{s}", @errorName(e)); } 
        \\}
    ;

    const rule = buildRule(.{});
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            no_swallow_error_source,
            .{},
            Config{
                .detect_catch_unreachable = severity,
                .detect_empty_catch = .off,
                .detect_empty_else = .off,
                .detect_else_unreachable = .off,
            },
            &.{
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch ({ unreachable; })",
                    .message = "Avoid swallowing error with catch unreachable",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch (unreachable)",
                    .message = "Avoid swallowing error with catch unreachable",
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
            },
        );

        try zlinter.testing.testRunRule(
            rule,
            no_swallow_error_source,
            .{},
            Config{
                .detect_catch_unreachable = .off,
                .detect_empty_catch = severity,
                .detect_empty_else = .off,
                .detect_else_unreachable = .off,
            },
            &.{
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch ({})",
                    .message = "Avoid swallowing error with empty catch",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "method() catch {}",
                    .message = "Avoid swallowing error with empty catch",
                },
            },
        );

        try zlinter.testing.testRunRule(
            rule,
            no_swallow_error_source,
            .{},
            Config{
                .detect_catch_unreachable = .off,
                .detect_empty_catch = .off,
                .detect_empty_else = severity,
                .detect_else_unreachable = .off,
            },
            &.{
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| ({})",
                    .message = "Avoid swallowing error with empty else",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| {}",
                    .message = "Avoid swallowing error with empty else",
                },
            },
        );

        try zlinter.testing.testRunRule(
            rule,
            no_swallow_error_source,
            .{},
            Config{
                .detect_catch_unreachable = .off,
                .detect_empty_catch = .off,
                .detect_empty_else = .off,
                .detect_else_unreachable = severity,
            },
            &.{
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| ({ unreachable; })",
                    .message = "Avoid swallowing error with else unreachable",
                },
                .{
                    .rule_id = "no_swallow_error",
                    .severity = severity,
                    .slice = "if (method()) {} else |_| (unreachable)",
                    .message = "Avoid swallowing error with else unreachable",
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
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        no_swallow_error_source,
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

test "no_swallow_error ordinary if else does not report" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main(cond: bool) void {
        \\    if (cond) {} else {}
        \\    if (cond) {} else unreachable;
        \\}
    ,
        .{},
        Config{
            .detect_catch_unreachable = .warning,
            .detect_empty_catch = .warning,
            .detect_empty_else = .warning,
            .detect_else_unreachable = .warning,
        },
        &.{},
    );
}

test "no_swallow_error handled catch does not report" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    method() catch |e| {
        \\        std.log.err("{s}", .{@errorName(e)});
        \\    };
        \\
        \\    method() catch |e| return e;
        \\}
    ,
        .{},
        Config{
            .detect_catch_unreachable = .warning,
            .detect_empty_catch = .warning,
            .detect_empty_else = .warning,
            .detect_else_unreachable = .warning,
        },
        &.{},
    );
}

test "no_swallow_error excludes test blocks by default" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\test "example" {
        \\    method() catch {};
        \\}
    ,
        .{},
        Config{
            .detect_catch_unreachable = .warning,
            .detect_empty_catch = .warning,
            .detect_empty_else = .warning,
            .detect_else_unreachable = .warning,
        },
        &.{},
    );
}

test "no_swallow_error reports test blocks when exclude_tests is false" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\test "example" {
        \\    method() catch {};
        \\}
    ,
        .{},
        Config{
            .detect_catch_unreachable = .warning,
            .detect_empty_catch = .warning,
            .detect_empty_else = .warning,
            .detect_else_unreachable = .warning,
            .exclude_tests = false,
        },
        &.{
            .{
                .rule_id = "no_swallow_error",
                .severity = .warning,
                .slice = "method() catch {}",
                .message = "Avoid swallowing error with empty catch",
            },
        },
    );
}

test "no_swallow_error exclude comments in catch" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn main() void {
        \\    method() catch {
        \\    // ignore
        \\   };
        \\}
    ,
        .{},
        Config{
            .detect_empty_catch = .warning,
            .exclude_comments = true,
        },
        &.{},
    );
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn main() void {
        \\    method() catch {
        \\    // ignore
        \\   };
        \\}
    ,
        .{},
        Config{
            .detect_empty_catch = .warning,
            .exclude_comments = false,
        },
        &.{
            .{
                .rule_id = "no_swallow_error",
                .severity = .warning,
                .slice =
                \\method() catch {
                \\    // ignore
                \\   }
                ,
                .message = "Avoid swallowing error with empty catch",
            },
        },
    );
}

test "no_swallow_error exclude comments in else" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn main() void {
        \\    if (method()) {
        \\      call();
        \\    } else |_| {
        \\    // ignore
        \\   }
        \\}
    ,
        .{},
        Config{
            .detect_empty_else = .@"error",
            .exclude_comments = true,
        },
        &.{},
    );
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn main() void {
        \\    if (method()) {
        \\      call();
        \\    } else |_| {
        \\    // ignore
        \\   }
        \\}
    ,
        .{},
        Config{
            .detect_empty_else = .@"error",
            .exclude_comments = false,
        },
        &.{
            .{
                .rule_id = "no_swallow_error",
                .severity = .@"error",
                .slice =
                \\if (method()) {
                \\      call();
                \\    } else |_| {
                \\    // ignore
                \\   }
                ,
                .message = "Avoid swallowing error with empty else",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
