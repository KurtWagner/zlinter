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
    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    _ = rule;
    _ = config;

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

        var seen_field: bool = false;
        for (connections.children orelse &.{}) |container_child| {
            // Declarations cannot appear between fields so once we see a field
            // simply read until we see something else to identify the chunk of
            // fields in source:
            switch (zlinter.shims.nodeTag(tree, container_child)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => seen_field = true,
                else => if (seen_field) break else continue,
            }

            const first_token = token: {
                var token = tree.firstToken(container_child);
                while (tree.tokens.items(.tag)[token - 1] == .doc_comment) token -= 1;
                break :token token;
            };

            const start = tree.tokenLocation(0, first_token);

            const last_token = tree.lastToken(container_child);
            const last = tree.tokenLocation(0, last_token);
            const last_token_value = tree.tokenSlice(last_token);

            std.debug.print("{s}: \n'''\n{s}\n'''\n\n", .{
                @tagName(zlinter.shims.nodeTag(tree, container_child)),
                tree.source[start.line_start + start.column .. last.line_start + last.column + last_token_value.len + 1],
            });
        }

        std.debug.print("\n----------\n\n", .{});
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

const std = @import("std");
const zlinter = @import("zlinter");
