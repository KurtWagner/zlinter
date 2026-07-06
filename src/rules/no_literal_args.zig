//! Disallow passing primitive literal numbers and booleans directly as
//! function arguments.
//!
//! Passing literal `1`, `0`, `true`, or `false` directly to a function is
//! ambiguous.
//!
//! These magic literals don’t explain what they mean. Consider using named
//! constants or if you're the owner of the API and there's multiple arguments,
//! consider introducing a struct argument

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

fn allDetectionsOff(config: Config) bool {
    return config.detect_char_literal == .off and
        config.detect_string_literal == .off and
        config.detect_number_literal == .off and
        config.detect_bool_literal == .off;
}

fn unwrapLiteralWrapperExpression(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;

    while (true) {
        switch (tree.nodeTag(current)) {
            .grouped_expression => current = tree.nodeData(current).node_and_token[0],
            .@"comptime" => current = tree.nodeData(current).node,
            else => return current,
        }
    }
}

fn calleeName(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    const unwrapped = unwrapLiteralWrapperExpression(tree, node);
    return switch (tree.nodeTag(unwrapped)) {
        // e.g., `parseInt(u32, "10", 10)`
        .identifier => tree.tokenSlice(tree.nodeMainToken(unwrapped)),
        // e.g., `.init()` or `Enum.init()`
        .enum_literal => blk: {
            const token = tree.nodeMainToken(unwrapped);
            if (tree.tokenTag(token) != .identifier) break :blk null;
            break :blk tree.tokenSlice(token);
        },
        // e.g., `std.fmt.parseInt(u32, "10", 10)`
        .field_access => fieldAccessCalleeName(tree, unwrapped),
        else => null,
    };
}

fn fieldAccessCalleeName(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    std.debug.assert(tree.nodeTag(node) == .field_access);

    const node_data = tree.nodeData(node).node_and_token;
    const lhs = node_data[0];
    const fn_name_token = node_data[1];

    if (tree.tokenTag(fn_name_token) != .identifier) return null;

    const lhs_unwrapped = unwrapLiteralWrapperExpression(tree, lhs);
    return switch (tree.nodeTag(lhs_unwrapped)) {
        .identifier, .enum_literal, .field_access => tree.tokenSlice(fn_name_token),
        else => null,
    };
}

fn literalKindForNumberSign(tree: Ast, node: Ast.Node.Index) ?LiteralKind {
    const operand = unwrapLiteralWrapperExpression(tree, tree.nodeData(node).node);
    return switch (tree.nodeTag(operand)) {
        .number_literal => .number,
        else => null,
    };
}

fn literalKindForArg(tree: Ast, node: Ast.Node.Index) ?LiteralKind {
    const unwrapped = unwrapLiteralWrapperExpression(tree, node);
    return switch (tree.nodeTag(unwrapped)) {
        .number_literal => .number,
        .string_literal, .multiline_string_literal => .string,
        .char_literal => .char,
        .negation, .negation_wrap => literalKindForNumberSign(tree, unwrapped),
        .identifier => switch (tree.tokens.items(.tag)[tree.nodeMainToken(unwrapped)]) {
            .string_literal, .multiline_string_literal_line => .string,
            .char_literal => .char,
            .number_literal => .number,
            else => @as(?LiteralKind, maybe_bool: {
                const slice = tree.getNodeSource(unwrapped);
                break :maybe_bool if (std.mem.eql(u8, slice, "false") or
                    std.mem.eql(u8, slice, "true"))
                    .bool
                else
                    null;
            }),
        },
        else => null,
    };
}

/// Runs the no_literal_args rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (allDetectionsOff(config)) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);
    var call_buffer: [1]Ast.Node.Index = undefined;

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const call = tree.fullCall(&call_buffer, node) orelse continue :nodes;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) {
            continue :nodes;
        }

        if (calleeName(tree, call.ast.fn_expr)) |fn_name| {
            for (config.exclude_fn_names) |exclude_fn_name|
                if (std.mem.eql(u8, exclude_fn_name, fn_name)) continue :nodes;
        }

        params: for (call.ast.params) |param_node| {
            const kind = literalKindForArg(tree, param_node) orelse
                continue :params;

            switch (kind) {
                .bool => if (config.detect_bool_literal != .off)
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_bool_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try session_arena.print("Avoid bool literal arguments as they're ambiguous.", .{}),
                    }),
                .string => if (config.detect_string_literal != .off)
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_string_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try session_arena.print("Avoid string literal arguments as they're ambiguous.", .{}),
                    }),
                .char => if (config.detect_char_literal != .off)
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_char_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try session_arena.print("Avoid char literal arguments as they're ambiguous.", .{}),
                    }),
                .number => if (config.detect_number_literal != .off)
                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = config.detect_number_literal,
                        .start = .startOfNode(tree, param_node),
                        .end = .endOfNode(tree, param_node),
                        .message = try session_arena.print("Avoid number literal arguments as they're ambiguous.", .{}),
                    }),
            }
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

test {
    std.testing.refAllDecls(@This());
}

test "bool" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  const flag = false;
        \\  doSomething(0, "hello", 'a', true, flag, false);
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .detect_number_literal = .off,
                .detect_bool_literal = severity,
                .detect_char_literal = .off,
                .detect_string_literal = .off,
            },
            &.{
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "true",
                    .message = "Avoid bool literal arguments as they're ambiguous.",
                },
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "false",
                    .message = "Avoid bool literal arguments as they're ambiguous.",
                },
            },
        );

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

test "wrapped literals" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  call((true), ((-1.2)), comptime 1, comptime true);
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .warning,
            .detect_bool_literal = .warning,
            .detect_char_literal = .off,
            .detect_string_literal = .off,
        },
        &.{
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "(true)",
                .message = "Avoid bool literal arguments as they're ambiguous.",
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "((-1.2))",
                .message = "Avoid number literal arguments as they're ambiguous.",
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "comptime 1",
                .message = "Avoid number literal arguments as they're ambiguous.",
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "comptime true",
                .message = "Avoid bool literal arguments as they're ambiguous.",
            },
        },
    );
}

test "nested call does not match outer argument" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  call(foo(true));
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .off,
            .detect_bool_literal = .warning,
            .detect_char_literal = .off,
            .detect_string_literal = .off,
        },
        &.{
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "true",
                .message = "Avoid bool literal arguments as they're ambiguous.",
            },
        },
    );
}

test "exclude function names for direct and field access callees" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  parseInt(u32, "10", 10);
        \\  std.fmt.parseInt(u32, "10", 10);
        \\  getParser().parseInt(u32, "10", 10);
        \\}
        \\
        \\const Parser = struct {
        \\  fn parseInt(self: @This(), comptime T: type, buffer: []const u8, base: u8) void {
        \\    _ = self;
        \\    _ = T;
        \\    _ = buffer;
        \\    _ = base;
        \\  }
        \\};
        \\
        \\fn getParser() Parser {
        \\  return .{};
        \\}
        \\
        \\fn parseInt(comptime T: type, buffer: []const u8, base: u8) void {
        \\  _ = T;
        \\  _ = buffer;
        \\  _ = base;
        \\}
        \\
        \\const std = @import("std");
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .warning,
            .detect_bool_literal = .off,
            .detect_char_literal = .off,
            .detect_string_literal = .off,
            .exclude_fn_names = &.{"parseInt"},
        },
        &.{
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "10",
                .message = "Avoid number literal arguments as they're ambiguous.",
            },
        },
    );
}

test "default excluded parseInt handles direct and qualified calls" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  parseInt(u32, "10", 10);
        \\  std.fmt.parseInt(u32, "10", 10);
        \\}
        \\
        \\const std = @import("std");
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .warning,
            .detect_bool_literal = .off,
            .detect_char_literal = .off,
            .detect_string_literal = .warning,
        },
        &.{},
    );
}

test "builtin call is ignored" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  _ = @as(bool, true);
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .off,
            .detect_bool_literal = .warning,
            .detect_char_literal = .off,
            .detect_string_literal = .off,
        },
        &.{},
    );
}

test "multiline string literals are detected when enabled" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        "pub fn main() void {\n" ++
        "  call(\n" ++
        "    \\\\line 1\n" ++
        "    \\\\line 2\n" ++
        "  );\n" ++
        "}\n";

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .off,
            .detect_bool_literal = .off,
            .detect_char_literal = .off,
            .detect_string_literal = .@"error",
        },
        &.{
            .{
                .rule_id = "no_literal_args",
                .severity = .@"error",
                .slice = "\\\\line 1\n    \\\\line 2",
                .message = "Avoid string literal arguments as they're ambiguous.",
            },
        },
    );
}

test "complex callee does not match exclude list" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  getFn()(true);
        \\}
        \\
        \\fn getFn() *const fn (bool) void {
        \\  return doSomething;
        \\}
        \\
        \\fn doSomething(value: bool) void {
        \\  _ = value;
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .off,
            .detect_bool_literal = .warning,
            .detect_char_literal = .off,
            .detect_string_literal = .off,
            .exclude_fn_names = &.{"getFn"},
        },
        &.{
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "true",
                .message = "Avoid bool literal arguments as they're ambiguous.",
            },
        },
    );
}

test "number" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  const num = 10;
        \\  a.b.c('a', "hello", false, true, 0, num, 0.5);
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .detect_number_literal = severity,
                .detect_bool_literal = .off,
                .detect_char_literal = .off,
                .detect_string_literal = .off,
            },
            &.{
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "0",
                    .message = "Avoid number literal arguments as they're ambiguous.",
                },
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "0.5",
                    .message = "Avoid number literal arguments as they're ambiguous.",
                },
            },
        );

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

test "number negatives" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  const num = 10;
        \\  const some_var = num;
        \\  call(-1, -0.5, -num, -some_var, ~1);
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .detect_number_literal = severity,
                .detect_bool_literal = .off,
                .detect_char_literal = .off,
                .detect_string_literal = .off,
            },
            &.{
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "-1",
                    .message = "Avoid number literal arguments as they're ambiguous.",
                },
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "-0.5",
                    .message = "Avoid number literal arguments as they're ambiguous.",
                },
            },
        );

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

test "char" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  const c = 'a';
        \\  call("hello", 1, true, false, c, 'a');
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .detect_number_literal = .off,
                .detect_bool_literal = .off,
                .detect_char_literal = severity,
                .detect_string_literal = .off,
            },
            &.{
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice = "'a'",
                    .message = "Avoid char literal arguments as they're ambiguous.",
                },
            },
        );

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

test "string" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn main() void {
        \\  const str = "hello";
        \\  field.call('a', false, 1, str, "hello");
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .detect_number_literal = .off,
                .detect_bool_literal = .off,
                .detect_char_literal = .off,
                .detect_string_literal = severity,
            },
            &.{
                .{
                    .rule_id = "no_literal_args",
                    .severity = severity,
                    .slice =
                    \\"hello"
                    ,
                    .message = "Avoid string literal arguments as they're ambiguous.",
                },
            },
        );

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

test "exclude tests" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\test {
        \\  call("hello", 1, true, 'a');
        \\}
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .warning,
            .detect_bool_literal = .warning,
            .detect_char_literal = .warning,
            .detect_string_literal = .@"error",
            .exclude_tests = false,
        },
        &.{
            .{
                .rule_id = "no_literal_args",
                .severity = .@"error",
                .slice =
                \\"hello"
                ,
                .message = "Avoid string literal arguments as they're ambiguous.",
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "1",
                .message = "Avoid number literal arguments as they're ambiguous.",
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "true",
                .message = "Avoid bool literal arguments as they're ambiguous.",
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .slice = "'a'",
                .message = "Avoid char literal arguments as they're ambiguous.",
            },
        },
    );

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .detect_number_literal = .warning,
            .detect_bool_literal = .warning,
            .detect_char_literal = .warning,
            .detect_string_literal = .warning,
            .exclude_tests = true,
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
