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
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_doc_comment),
        .run = &run,
    };
}

/// Runs the require_doc_comment rule.
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

    var arena_mem: [32 * 1024]u8 = undefined;
    var arena_buffer = std.heap.FixedBufferAllocator.init(&arena_mem);
    const arena = arena_buffer.allocator();

    const root: zlinter.shims.NodeIndexShim = .root;

    if (config.file_severity != .off) {
        defer arena_buffer.reset();
        if (!try hasDocComments(arena, tree, root.toNodeIndex())) {
            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = config.file_severity,
                .start = .startOfNode(tree, root.toNodeIndex()),
                .end = .startOfNode(tree, root.toNodeIndex()),
                .message = try allocator.dupe(u8, "File is missing a doc comment"),
            });
        }
    }
    if (config.private_severity == .off and config.public_severity == .off) return null;

    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    var fn_decl_buffer: [1]std.zig.Ast.Node.Index = undefined;

    skip: while (try it.next()) |tuple| {
        defer arena_buffer.reset();

        const node, const connections = tuple;
        _ = connections;

        const tag = zlinter.shims.nodeTag(tree, node.toNodeIndex());

        switch (tag) {
            .fn_decl => if (tree.fullFnProto(&fn_decl_buffer, node.toNodeIndex())) |fn_decl| {
                const severity, const label = if (isFnPrivate(tree, fn_decl))
                    .{ config.private_severity, "Private" }
                else
                    .{ config.public_severity, "Public" };
                if (severity == .off) continue :skip;

                if (try hasDocComments(arena, tree, node.toNodeIndex())) continue :skip;

                try lint_problems.append(allocator, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(node.toNodeIndex())),
                    .end = .endOfNode(tree, fn_decl.ast.proto_node),
                    .message = try std.fmt.allocPrint(allocator, "{s} function is missing a doc comment", .{label}),
                });
            },
            else => if (tree.fullVarDecl(node.toNodeIndex())) |var_decl| {
                const severity, const label = if (isVarPrivate(tree, var_decl))
                    .{ config.private_severity, "Private" }
                else
                    .{ config.public_severity, "Public" };
                if (severity == .off) continue :skip;

                if (try hasDocComments(arena, tree, node.toNodeIndex())) continue :skip;

                try lint_problems.append(allocator, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(node.toNodeIndex())),
                    .end = .endOfToken(tree, var_decl.ast.mut_token + 1),
                    .message = try std.fmt.allocPrint(allocator, "{s} declaration is missing a doc comment", .{label}),
                });
            },
        }

        continue :skip;
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

fn hasDocComments(arena: std.mem.Allocator, tree: std.zig.Ast, node: std.zig.Ast.Node.Index) !bool {
    const comments = try zlinter.zls.Analyser.getDocComments(
        arena,
        tree,
        node,
    ) orelse return false;
    return comments.len > 0;
}

fn isFnPrivate(tree: std.zig.Ast, fn_decl: std.zig.Ast.full.FnProto) bool {
    const visibility_token = fn_decl.visib_token orelse return true;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => false,
        else => true,
    };
}

fn isVarPrivate(tree: std.zig.Ast, var_decl: std.zig.Ast.full.VarDecl) bool {
    const visibility_token = var_decl.visib_token orelse return true;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => false,
        else => true,
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
        var config = Config{ .public_severity = severity };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
            source,
            .{ .config = &config },
        )).?;
        defer result.deinit(std.testing.allocator);

        try std.testing.expectStringEndsWith(
            result.file_path,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
        );

        try zlinter.testing.expectProblemsEqual(
            &[_]zlinter.results.LintProblem{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .start = .{
                        .byte_offset = 74,
                        .line = 7,
                        .column = 0,
                    },
                    .end = .{
                        .byte_offset = 87,
                        .line = 7,
                        .column = 13,
                    },
                    .message = "Public declaration is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .start = .{
                        .byte_offset = 0,
                        .line = 0,
                        .column = 0,
                    },
                    .end = .{
                        .byte_offset = 19,
                        .line = 0,
                        .column = 19,
                    },
                    .message = "Public function is missing a doc comment",
                },
            },
            result.problems,
        );
    }
    { // off
        var config = Config{ .public_severity = .off };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
            source,
            .{ .config = &config },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(null, result);
    }
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
        var config = Config{ .private_severity = severity };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
            source,
            .{ .config = &config },
        )).?;
        defer result.deinit(std.testing.allocator);

        try std.testing.expectStringEndsWith(
            result.file_path,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
        );

        try zlinter.testing.expectProblemsEqual(
            &[_]zlinter.results.LintProblem{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .start = .{
                        .byte_offset = 66,
                        .line = 7,
                        .column = 0,
                    },
                    .end = .{
                        .byte_offset = 75,
                        .line = 7,
                        .column = 9,
                    },
                    .message = "Private declaration is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .start = .{
                        .byte_offset = 0,
                        .line = 0,
                        .column = 0,
                    },
                    .end = .{
                        .byte_offset = 15,
                        .line = 0,
                        .column = 15,
                    },
                    .message = "Private function is missing a doc comment",
                },
            },
            result.problems,
        );
    }
    { // off
        var config = Config{ .private_severity = .off };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
            source,
            .{ .config = &config },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(null, result);
    }
}

test "require_doc_comment - file" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        var config = Config{ .file_severity = severity };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
            source,
            .{ .config = &config },
        )).?;
        defer result.deinit(std.testing.allocator);

        try std.testing.expectStringEndsWith(
            result.file_path,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
        );

        try zlinter.testing.expectProblemsEqual(
            &[_]zlinter.results.LintProblem{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .start = .{
                        .byte_offset = 0,
                        .line = 0,
                        .column = 0,
                    },
                    .end = .{
                        .byte_offset = 0,
                        .line = 0,
                        .column = 0,
                    },
                    .message = "File is missing a doc comment",
                },
            },
            result.problems,
        );
    }
    { // off
        var config = Config{ .file_severity = .off };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/doc_comments.zig"),
            source,
            .{ .config = &config },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(null, result);
    }
}

const std = @import("std");
const zlinter = @import("zlinter");
