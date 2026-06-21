//! Enforce a consistent, predictable order for fields in structs, enums, and unions.
//!
//! `field_ordering` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places.
//!
//! **Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**

/// Config for field_ordering rule.
pub const Config = struct {
    /// Order and severity for union fields. If you're setting this and use
    /// tagged unions (e.g., `union(MyEnum)`) then you will also need to set
    /// the same order for enums.
    union_field_order: zlinter.rules.LintTextOrderWithSeverity = .{
        .order = .alphabetical_ascending,
        .severity = .warning,
    },

    /// Order and severity for struct fields
    struct_field_order: zlinter.rules.LintTextOrderWithSeverity = .off,

    /// Whether to check order of packed structs (e.g., `packed struct(u32) { .. }`).
    /// You probably never want to enforce order of packed structs, so best to
    /// leave as `true` unless you're certain.
    exclude_packed_structs: bool = true,

    /// Whether to check order of extern structs (e.g., `extern struct { .. }`).
    /// You probably never want to enforce order of extern structs, so best to
    /// leave as `true` unless you're certain.
    exclude_extern_structs: bool = true,

    /// Order and severity for enum fields. If you're setting this and use
    /// tagged unions (e.g., `union(MyEnum)`) then you will also need to set
    /// the same order for unions.
    enum_field_order: zlinter.rules.LintTextOrderWithSeverity = .{
        .order = .alphabetical_ascending,
        .severity = .warning,
    },
};

/// Builds and returns the field_ordering rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return zlinter.rules.LintRule{
        .rule_id = @tagName(.field_ordering),
        .run = &run,
    };
}

/// Runs the field_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    var container_decl_buffer: [2]Ast.Node.Index = undefined;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const order_with_severity: zlinter.rules.LintTextOrderWithSeverity, const container_kind_name: []const u8 = kind: {
            if (tree.fullContainerDecl(
                &container_decl_buffer,
                node,
            )) |container_decl| {
                break :kind switch (tree.tokens.items(.tag)[tree.nodeMainToken(node)]) {
                    .keyword_union => .{ config.union_field_order, "Union" },
                    .keyword_struct => {
                        if (container_decl.layout_token) |layout_token| {
                            if (config.exclude_extern_structs and tree.tokens.items(.tag)[layout_token] == .keyword_extern) {
                                break :kind null;
                            }
                            if (config.exclude_packed_structs and tree.tokens.items(.tag)[layout_token] == .keyword_packed) {
                                break :kind null;
                            }
                        }
                        break :kind .{ config.struct_field_order, "Struct" };
                    },
                    .keyword_enum => .{ config.enum_field_order, "Enum" },
                    else => null,
                };
            }
            break :kind null;
        } orelse continue :nodes;

        if (order_with_severity.order == .off or order_with_severity.severity == .off) {
            continue :nodes;
        }

        var actual_order = std.ArrayList(Ast.Node.Index).empty;
        var expected_order = std.ArrayList(Ast.Node.Index).empty;

        var sorted_queue: std.PriorityQueue(
            Field,
            struct { zlinter.rules.LintTextOrder },
            Field.cmp,
        ) = .initContext(.{order_with_severity.order});

        var seen_field: bool = false;
        children: for (connections.children orelse &.{}) |container_child| {
            // Declarations cannot appear between fields so once we see a field
            // simply read until we see something else to identify the chunk of
            // fields in source:
            const name_token = token: switch (tree.nodeTag(container_child)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    seen_field = true;
                    break :token tree.nodeMainToken(container_child);
                },
                else => if (seen_field) break :children else continue :children,
            };

            try actual_order.append(rule_arena, container_child);
            try sorted_queue.push(rule_arena, .{
                .name = tree.tokenSlice(name_token),
                .node = container_child,
            });
        }

        // Find the first and last field that are out of order (if any)
        var i: usize = 0;
        var maybe_first_problem_index: ?usize = null; // Inclusive
        var maybe_last_problem_index: ?usize = null; // Inclusive
        while (sorted_queue.pop()) |field| : (i += 1) {
            try expected_order.append(rule_arena, field.node);
            if (field.node != actual_order.items[i]) {
                maybe_first_problem_index = maybe_first_problem_index orelse i;
                maybe_last_problem_index = i;
            }
        }

        if (maybe_first_problem_index) |first_problem_index| {
            const last_problem_index = maybe_last_problem_index.?;

            const actual_start, const actual_end =
                nodeSpanIncludingComments(
                    tree,
                    actual_order.items[first_problem_index],
                    actual_order.items[last_problem_index],
                    .{
                        .consume_trailing_comma = true,
                    },
                );

            var expected_writer: std.Io.Writer.Allocating = .init(session_arena);

            const last_node = expected_order.items[expected_order.items.len - 1];
            for (expected_order.items[first_problem_index .. last_problem_index + 1]) |current_node| {
                const is_last_field = current_node == last_node;

                const expected_start, const expected_end = nodeSpanIncludingComments(
                    tree,
                    current_node,
                    current_node,
                    .{},
                );
                const is_multiline = is_multiline: {
                    for (expected_start.byte_offset..expected_end.byte_offset + 1) |byte| {
                        if (tree.source[byte] == '\n') break :is_multiline true;
                    }
                    break :is_multiline false;
                };

                expected_writer.writer.writeAll(
                    tree.source[expected_start.byte_offset .. expected_end.byte_offset + 1],
                ) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                };
                if (!is_last_field or is_multiline) {
                    expected_writer.writer.writeByte(',') catch |err| switch (err) {
                        error.WriteFailed => return error.OutOfMemory,
                    };
                }
            }

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = order_with_severity.severity,
                .start = actual_start,
                .end = actual_end,
                .message = try std.fmt.allocPrint(session_arena, "{s} fields should be in {s} order", .{
                    container_kind_name,
                    order_with_severity.order.name(),
                }),
                .fix = .{
                    .start = actual_start.byte_offset,
                    .end = actual_end.byte_offset + 1, // + 1 as fix is exclusive
                    .text = try expected_writer.toOwnedSlice(),
                },
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            lint_problems.items,
        )
    else
        null;
}

/// Span between two nodes (or the same node) including comments and leading
/// whitespace like newlines.
fn nodeSpanIncludingComments(
    tree: Ast,
    first_node: Ast.Node.Index,
    last_node: Ast.Node.Index,
    options: struct { consume_trailing_comma: bool = false },
) struct {
    zlinter.results.LintProblemLocation,
    zlinter.results.LintProblemLocation,
} {
    const first_token = firstTokenIncludingComments(tree, first_node);
    const prev_end: zlinter.results.LintProblemLocation = .endOfToken(tree, first_token - 1);
    const start: zlinter.results.LintProblemLocation = .{
        .byte_offset = prev_end.byte_offset + 1,
    };

    var last_token = tree.lastToken(last_node);
    if (options.consume_trailing_comma and tree.tokens.items(.tag)[last_token + 1] == .comma) last_token += 1;
    const end: zlinter.results.LintProblemLocation = .endOfToken(tree, last_token);

    return .{ start, end };
}

fn firstTokenIncludingComments(tree: Ast, node: Ast.Node.Index) Ast.TokenIndex {
    var token = tree.firstToken(node);
    while (tree.tokens.items(.tag)[token - 1] == .doc_comment) token -= 1;
    return token;
}

const Field = struct {
    name: []const u8,
    node: Ast.Node.Index,

    fn cmp(session: struct { zlinter.rules.LintTextOrder }, lhs: Field, rhs: Field) std.math.Order {
        const order = session.@"0";
        return order.cmp(lhs.name, rhs.name);
    }
};

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
