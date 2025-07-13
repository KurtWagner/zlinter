//! Enforce a consistent, predictable order for fields in structs, enums, and unions.

/// Config for field_ordering rule.
pub const Config = struct {};

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
    _ = config;

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: zlinter.shims.NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    var container_decl_buffer: [2]std.zig.Ast.Node.Index = undefined;

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        if (tree.fullContainerDecl(
            &container_decl_buffer,
            node.toNodeIndex(),
        ) == null) continue :skip;

        var insertion_order = std.ArrayList(std.zig.Ast.Node.Index).init(allocator);
        defer insertion_order.deinit();

        var sorted_order = std.PriorityQueue(
            Field,
            void,
            Field.cmp,
        ).init(allocator, {});
        defer sorted_order.deinit();

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

            try insertion_order.append(container_child);
            try sorted_order.add(.{
                .name = tree.tokenSlice(name_token),
                .node = container_child,
            });
        }

        // Find the first and last field that are out of order (if any)
        var i: usize = 0;
        var maybe_first_problem_index: ?usize = null; // Inclusive
        var maybe_last_problem_index: ?usize = null; // Inclusive
        while (sorted_order.removeOrNull()) |field| : (i += 1) {
            if (field.node != insertion_order.items[i]) {
                maybe_first_problem_index = maybe_first_problem_index orelse i;
                maybe_last_problem_index = i;
            }
        }

        if (maybe_first_problem_index) |first_problem_index| {
            const last_problem_index = maybe_last_problem_index.?;

            const first_token = firstTokenIncludingComments(tree, insertion_order.items[first_problem_index]);
            const start: zlinter.results.LintProblemLocation = .startOfToken(tree, first_token);

            const last_token = tree.lastToken(insertion_order.items[last_problem_index]);
            const end: zlinter.results.LintProblemLocation = .endOfToken(tree, last_token);

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = .warning,
                .start = start,
                .end = end,
                .message = try allocator.dupe(u8, "Fields should be in alphabetical order"),
                .fix = .{
                    .start = start.byte_offset,
                    .end = end.byte_offset + 1, // + 1 as fix is exclusive
                    .text = "hello",
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

fn firstTokenIncludingComments(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) std.zig.Ast.TokenIndex {
    var token = tree.firstToken(node);
    while (tree.tokens.items(.tag)[token - 1] == .doc_comment) token -= 1;
    return token;
}

const Field = struct {
    name: []const u8,
    node: std.zig.Ast.Node.Index,

    fn cmp(_: void, lhs: Field, rhs: Field) std.math.Order {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name);
    }
};

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
