//! Enforce a consistent, predictable order for fields in structs, enums, and unions.

/// Config for field_ordering rule.
pub const Config = struct {
    /// Order and severity for union fields
    union_field_order: zlinter.rules.LintTextOrderWithSeverity = .{
        .order = .alphabetical_ascending,
        .severity = .warning,
    },

    /// Order and severity for struct fields
    struct_field_order: zlinter.rules.LintTextOrderWithSeverity = .off,

    /// Order and severity for enum fields
    enum_field_order: zlinter.rules.LintTextOrderWithSeverity = .{
        .order = .alphabetical_ascending,
        .severity = .warning,
    },
};

/// Builds and returns the field_ordering rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;
    return zlinter.rules.LintRule{
        .rule_id = @tagName(.field_ordering),
        .run = &run,
    };
}

/// Runs the field_ordering rule.
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

    var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const order_with_severity: zlinter.rules.LintTextOrderWithSeverity, const container_kind_name: []const u8 = kind: {
            if (tree.fullContainerDecl(
                &container_decl_buffer,
                node.toNodeIndex(),
            )) |_| {
                break :kind switch (tree.tokens.items(.tag)[zlinter.shims.nodeMainToken(tree, node.toNodeIndex())]) {
                    .keyword_union => .{ config.union_field_order, "Union" },
                    .keyword_struct => .{ config.struct_field_order, "Struct" },
                    .keyword_enum => .{ config.enum_field_order, "Enum" },
                    else => null,
                };
            }
            break :kind null;
        } orelse continue :skip;

        if (order_with_severity.order == .off or order_with_severity.severity == .off) {
            continue :skip;
        }

        var actual_order = std.ArrayList(std.zig.Ast.Node.Index).init(allocator);
        defer actual_order.deinit();

        var expected_order = std.ArrayList(std.zig.Ast.Node.Index).init(allocator);
        defer expected_order.deinit();

        var sorted_queue = std.PriorityQueue(
            Field,
            struct { zlinter.rules.LintTextOrder },
            Field.cmp,
        ).init(allocator, .{order_with_severity.order});
        defer sorted_queue.deinit();

        var seen_field: bool = false;
        children: for (connections.children orelse &.{}) |container_child| {
            // Declarations cannot appear between fields so once we see a field
            // simply read until we see something else to identify the chunk of
            // fields in source:
            const name_token = token: switch (zlinter.shims.nodeTag(tree, container_child)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    seen_field = true;
                    break :token zlinter.shims.nodeMainToken(tree, container_child);
                },
                else => if (seen_field) break :children else continue :children,
            };

            try actual_order.append(container_child);
            try sorted_queue.add(.{
                .name = tree.tokenSlice(name_token),
                .node = container_child,
            });
        }

        // Find the first and last field that are out of order (if any)
        var i: usize = 0;
        var maybe_first_problem_index: ?usize = null; // Inclusive
        var maybe_last_problem_index: ?usize = null; // Inclusive
        while (sorted_queue.removeOrNull()) |field| : (i += 1) {
            try expected_order.append(field.node);
            if (field.node != actual_order.items[i]) {
                maybe_first_problem_index = maybe_first_problem_index orelse i;
                maybe_last_problem_index = i;
            }
        }

        if (maybe_first_problem_index) |first_problem_index| {
            const last_problem_index = maybe_last_problem_index.?;

            const actual_start, const actual_end = nodeSpanIncludingComments(
                tree,
                actual_order.items[first_problem_index],
                actual_order.items[last_problem_index],
            );

            var expected_source = std.ArrayList(u8).init(allocator);
            defer expected_source.deinit();

            for (expected_order.items[first_problem_index .. last_problem_index + 1]) |expected_node| {
                const expected_start, const expected_end = nodeSpanIncludingComments(
                    tree,
                    expected_node,
                    expected_node,
                );

                try expected_source.appendSlice(tree.source[expected_start.byte_offset .. expected_end.byte_offset + 1]);
                try expected_source.append(','); // Fields comma delimited.
            }

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = .warning,
                .start = actual_start,
                .end = actual_end,
                .message = try std.fmt.allocPrint(allocator, "{s} fields should be in alphabetical order", .{container_kind_name}),
                .fix = .{
                    .start = actual_start.byte_offset,
                    .end = actual_end.byte_offset + 1, // + 1 as fix is exclusive
                    .text = try expected_source.toOwnedSlice(),
                },
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

// TODO: This needs unit tests
/// Span between two nodes (or the same node) including comments and leading
/// whitespace like newlines.
fn nodeSpanIncludingComments(
    tree: std.zig.Ast,
    first_node: std.zig.Ast.Node.Index,
    last_node: std.zig.Ast.Node.Index,
) struct {
    zlinter.results.LintProblemLocation,
    zlinter.results.LintProblemLocation,
} {
    const first_token = firstTokenIncludingComments(tree, first_node);
    const prev_end: zlinter.results.LintProblemLocation = .endOfToken(tree, first_token - 1);
    const start: zlinter.results.LintProblemLocation = .{
        .byte_offset = prev_end.byte_offset + 1,
        .line = if (tree.source[prev_end.byte_offset] == '\n') prev_end.line + 1 else prev_end.line,
        .column = if (tree.source[prev_end.byte_offset] == '\n') 0 else prev_end.column + 1,
    };

    const last_token = tree.lastToken(last_node);
    const end: zlinter.results.LintProblemLocation = .endOfToken(tree, last_token);

    return .{ start, end };
}

fn firstTokenIncludingComments(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) std.zig.Ast.TokenIndex {
    var token = tree.firstToken(node);
    while (tree.tokens.items(.tag)[token - 1] == .doc_comment) token -= 1;
    return token;
}

const Field = struct {
    name: []const u8,
    node: std.zig.Ast.Node.Index,

    fn cmp(context: struct { zlinter.rules.LintTextOrder }, lhs: Field, rhs: Field) std.math.Order {
        const order = context.@"0";
        return order.cmp(lhs.name, rhs.name);
    }
};

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
