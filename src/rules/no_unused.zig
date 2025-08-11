//! Enforces that container declarations are referenced.
//!
//! `no_unused` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places.
//!
//! **Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**

/// Config for no_unused rule.
pub const Config = struct {
    /// The severity for container declarations that are unused (off, warning, error).
    container_declaration: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_unused rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_unused),
        .run = &run,
    };
}

/// Runs the no_unused rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;
    const token_tags = tree.tokens.items(.tag);

    // Store an index of referenced identifiers and field accesses on the
    // container, this is then used to check whether a root declaration is
    // being used.
    var container_references = map: {
        var map = std.StringHashMapUnmanaged(void).empty;

        var node: NodeIndexShim = .root;
        while (node.index < tree.nodes.len) : (node.index += 1) {
            switch (shims.nodeTag(tree, node.toNodeIndex())) {
                .identifier => try map.put(allocator, tree.tokenSlice(shims.nodeMainToken(tree, node.toNodeIndex())), {}),
                .field_access => if (try isFieldAccessOfRootContainer(doc, node.toNodeIndex())) {
                    const node_data = shims.nodeData(tree, node.toNodeIndex());
                    try map.put(allocator, tree.tokenSlice(switch (zlinter.version.zig) {
                        .@"0.14" => node_data.rhs,
                        .@"0.15" => node_data.node_and_token.@"1",
                    }), {});
                },
                else => {},
            }
        }
        break :map map;
    };
    defer container_references.deinit(allocator);

    for (tree.rootDecls()) |decl| {
        const problem: ?struct { first: Ast.TokenIndex, last: Ast.TokenIndex } = problem: {
            if (tree.fullVarDecl(decl)) |var_decl| {
                if (var_decl.visib_token) |visib_token|
                    if (token_tags[visib_token] == .keyword_pub)
                        break :problem null;

                if (var_decl.extern_export_token) |extern_export_token|
                    if (token_tags[extern_export_token] == .keyword_export)
                        break :problem null;

                if (!container_references.contains(tree.tokenSlice(var_decl.ast.mut_token + 1))) {
                    break :problem .{
                        .first = tree.firstToken(decl),
                        .last = tree.lastToken(decl) + 1, // "+ 1" to consume the semicolon for this statement
                    };
                }
            } else {
                var buffer: [1]Ast.Node.Index = undefined;
                if (namedFnDeclProto(tree, &buffer, decl)) |fn_proto| {
                    if (fn_proto.visib_token) |token|
                        if (token_tags[token] == .keyword_pub)
                            break :problem null;

                    if (fn_proto.extern_export_inline_token) |token|
                        if (token_tags[token] == .keyword_export)
                            break :problem null;

                    if (!container_references.contains(tree.tokenSlice(fn_proto.name_token.?))) {
                        break :problem .{
                            .first = tree.firstToken(decl),
                            .last = tree.lastToken(decl),
                        };
                    }
                }
            }
            break :problem null;
        };

        if (problem) |p| {
            const first_token = p.first;
            const last_token = p.last;

            const start = tree.tokenLocation(0, first_token);
            const end = tree.tokenLocation(0, last_token);

            const start_newline: bool = if (first_token > 0) tree.tokenLocation(0, first_token - 1).line < start.line else true;
            const end_newline: bool = if (last_token + 1 < tree.tokens.len) tree.tokenLocation(0, last_token + 1).line > end.line else true;
            const end_offset: usize = if (start_newline and end_newline) 1 else 0;

            try lint_problems.append(allocator, .{
                .rule_id = rule.rule_id,
                .severity = config.container_declaration,
                .start = .startOfToken(tree, first_token),
                .end = .endOfToken(tree, last_token),
                .message = try allocator.dupe(u8, "Unused declaration"),
                .fix = .{
                    .start = start.line_start,
                    .end = end.line_end + end_offset,
                    .text = "",
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

/// Returns fn proto if node is fn declaration and has a name token.
fn namedFnDeclProto(
    tree: Ast,
    buffer: *[1]Ast.Node.Index,
    node: Ast.Node.Index,
) ?Ast.full.FnProto {
    if (switch (shims.nodeTag(tree, node)) {
        .fn_decl => tree.fullFnProto(buffer, switch (zlinter.version.zig) {
            .@"0.14" => shims.nodeData(tree, node).lhs,
            .@"0.15" => shims.nodeData(tree, node).node_and_node.@"0",
        }),
        else => null,
    }) |fn_proto| {
        if (fn_proto.name_token != null) return fn_proto;
    }
    return null;
}

fn isFieldAccessOfRootContainer(doc: zlinter.session.LintDocument, node: Ast.Node.Index) error{OutOfMemory}!bool {
    std.debug.assert(shims.nodeTag(doc.handle.tree, node) == .field_access);

    const tree = doc.handle.tree;

    const node_data = shims.nodeData(tree, node);
    const lhs = switch (zlinter.version.zig) {
        .@"0.14" => node_data.lhs,
        .@"0.15" => node_data.node_and_token.@"0",
    };

    if (try doc.resolveTypeOfNode(lhs)) |t| {
        switch (t.resolveDeclLiteralResultType().data) {
            .container => |scope_handle| return isContainerRoot(scope_handle),
            else => {},
        }
    }
    return false;
}

fn isContainerRoot(container: anytype) bool {
    return switch (zlinter.version.zig) {
        .@"0.14" => container.toNode() == 0,
        .@"0.15" => container.scope_handle.toNode() == .root,
    };
}

test "no_unused" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
        \\
        \\const a = @import("a");
        \\pub const c = @import("c");
        \\var Ok = struct {
        \\ name: u32,
        \\};
        \\
        \\fn usedFn() void {}
        \\fn unusedFn() void {
        \\   usedFn();
        \\}
    ,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .start = .{
                    .byte_offset = 1,
                    .line = 1,
                    .column = 0,
                },
                .end = .{
                    .byte_offset = 23,
                    .line = 1,
                    .column = 22,
                },
                .message = "Unused declaration",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 1,
                    .end = 25,
                    .text = "",
                },
            },
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .start = .{
                    .byte_offset = 53,
                    .line = 3,
                    .column = 0,
                },
                .end = .{
                    .byte_offset = 84,
                    .line = 5,
                    .column = 1,
                },
                .message = "Unused declaration",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 53,
                    .end = 86,
                    .text = "",
                },
            },
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .start = .{
                    .byte_offset = 107,
                    .line = 8,
                    .column = 0,
                },
                .end = .{
                    .byte_offset = 141,
                    .line = 10,
                    .column = 0,
                },
                .message = "Unused declaration",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 107,
                    .end = 142,
                    .text = "",
                },
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
