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
    detect_number_literal: zlinter.rules.LintProblemSeverity = .warning,

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
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
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
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;
    var call_buffer: [1]std.zig.Ast.Node.Index = undefined;

    const root: zlinter.shims.NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

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

            // if configured, skip if a parent is a test block
            if (config.exclude_tests) {
                var next_parent = connections.parent;
                while (next_parent) |parent| {
                    if (zlinter.shims.nodeTag(tree, parent) == .test_decl) continue :skip;

                    next_parent = doc.lineage.items(.parent)[zlinter.shims.NodeIndexShim.init(parent).index];
                }
            }

            const fn_name = tree.tokenSlice(tree.lastToken(call.ast.fn_expr));
            for (config.exclude_fn_names) |exclude_fn_name| {
                if (std.mem.eql(u8, exclude_fn_name, fn_name)) continue :skip;
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
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
        source,
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
    );

    inline for (&.{ "true,", "0,", "0.5,", "false)" }, 0..) |slice, i| {
        try std.testing.expectEqualStrings(slice, result.problems[i].sliceSource(source));
    }

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .start = .{
                    .byte_offset = 68,
                    .line = 3,
                    .column = 7,
                },
                .end = .{
                    .byte_offset = 72,
                    .line = 3,
                    .column = 11,
                },
                .message = "Avoid bool literal arguments as they're ambiguous.",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .start = .{
                    .byte_offset = 74,
                    .line = 3,
                    .column = 13,
                },
                .end = .{
                    .byte_offset = 75,
                    .line = 3,
                    .column = 14,
                },
                .message = "Avoid number literal arguments as they're ambiguous.",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .start = .{
                    .byte_offset = 82,
                    .line = 3,
                    .column = 21,
                },
                .end = .{
                    .byte_offset = 85,
                    .line = 3,
                    .column = 24,
                },
                .message = "Avoid number literal arguments as they're ambiguous.",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "no_literal_args",
                .severity = .warning,
                .start = .{
                    .byte_offset = 93,
                    .line = 3,
                    .column = 32,
                },
                .end = .{
                    .byte_offset = 98,
                    .line = 3,
                    .column = 37,
                },
                .message = "Avoid bool literal arguments as they're ambiguous.",
                .disabled_by_comment = false,
                .fix = null,
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
