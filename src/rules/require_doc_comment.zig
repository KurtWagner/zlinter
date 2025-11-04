//! Require doc comments for all public functions, types, and constants.
//!
//! Unless you're maintaining an open API used by other projects this rule is more than
//! likely unnecessary, and in some cases, can encourage avoidable noise on
//! otherwise simple APIs.

/// Config for require_doc_comment rule.
pub const Config = struct {
    /// The severity when missing doc comments on public declarations (off, warning, error).
    public_severity: zlinter.rules.LintProblemSeverity = .warning,

    /// The severity when missing doc comments on private declarations (off, warning, error).
    private_severity: zlinter.rules.LintProblemSeverity = .off,

    /// The severity when missing doc comments on top of the file (off, warning, error).
    file_severity: zlinter.rules.LintProblemSeverity = .off,
};

/// Builds and returns the require_doc_comment rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_doc_comment),
        .run = &run,
    };
}

/// Runs the require_doc_comment rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;

    if (config.file_severity != .off) {
        if (!try hasDocComments(tree, root.toNodeIndex())) {
            try lint_problems.append(gpa, .{
                .rule_id = rule.rule_id,
                .severity = config.file_severity,
                .start = .startOfNode(tree, root.toNodeIndex()),
                .end = .startOfNode(tree, root.toNodeIndex()),
                .message = try gpa.dupe(u8, "File is missing a doc comment"),
            });
        }
    }
    if (config.private_severity == .off and config.public_severity == .off) return null;

    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    var fn_decl_buffer: [1]Ast.Node.Index = undefined;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const tag = shims.nodeTag(tree, node.toNodeIndex());

        switch (tag) {
            .fn_decl => if (tree.fullFnProto(&fn_decl_buffer, node.toNodeIndex())) |fn_decl| {
                const severity, const label = switch (zlinter.ast.fnProtoVisibility(tree, fn_decl)) {
                    .private => .{ config.private_severity, "Private" },
                    .public => .{ config.public_severity, "Public" },
                };
                if (severity == .off) continue :nodes;

                if (try hasDocComments(tree, node.toNodeIndex())) continue :nodes;

                try lint_problems.append(gpa, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(node.toNodeIndex())),
                    .end = .endOfNode(tree, fn_decl.ast.proto_node),
                    .message = try std.fmt.allocPrint(gpa, "{s} function is missing a doc comment", .{label}),
                });
            },
            else => if (tree.fullVarDecl(node.toNodeIndex())) |var_decl| {
                const severity, const label = switch (zlinter.ast.varDeclVisibility(tree, var_decl)) {
                    .private => .{ config.private_severity, "Private" },
                    .public => .{ config.public_severity, "Public" },
                };
                if (severity == .off) continue :nodes;

                if (try hasDocComments(tree, node.toNodeIndex())) continue :nodes;

                try lint_problems.append(gpa, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(node.toNodeIndex())),
                    .end = .endOfToken(tree, var_decl.ast.mut_token + 1),
                    .message = try std.fmt.allocPrint(gpa, "{s} declaration is missing a doc comment", .{label}),
                });
            },
        }

        continue :nodes;
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

fn hasDocComments(tree: Ast, node: Ast.Node.Index) !bool {
    return switch (tree.nodeTag(node)) {
        .root => tree.tokenTag(0) == .container_doc_comment,
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .fn_decl,
        => zlinter.zls.Analyser.getDocCommentTokenIndex(
            &tree,
            tree.nodeMainToken(node),
        ) != null,
        inline else => |v| @panic("Unhandled tag " ++ @tagName(v)),
    };
}

test "require_doc_comment - public" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn noDoc() void {
        \\}
        \\
        \\/// Doc comment
        \\pub fn hasDocComment() void {
        \\}
        \\
        \\pub const name = "jack";
        \\
        \\/// Doc comment
        \\pub const name_with_comment = "jack";
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .public_severity = severity },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "pub const name",
                    .message = "Public declaration is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "pub fn noDoc() void",
                    .message = "Public function is missing a doc comment",
                },
            },
        );
    }

    // off
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .public_severity = .off },
        &.{},
    );
}

test "require_doc_comment - private" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\fn noDoc() void {
        \\}
        \\
        \\/// Doc comment
        \\fn hasDocComment() void {
        \\}
        \\
        \\const name = "jack";
        \\
        \\/// Doc comment
        \\const name_with_comment = "jack";
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .private_severity = severity },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "const name",
                    .message = "Private declaration is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "fn noDoc() void",
                    .message = "Private function is missing a doc comment",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .private_severity = .off },
        &.{},
    );
}

test "require_doc_comment - file" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .file_severity = severity },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "",
                    .message = "File is missing a doc comment",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .file_severity = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
