//! Enforces that references aren't deprecated (i.e., doc commented with `Deprecated: `)

/// Config for no_deprecated rule.
pub const Config = struct {
    severity: zlinter.LintProblemSeverity = .warning,
};

/// Builds and returns the no_deprecated rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.no_deprecated),
        .run = &run,
    };
}

/// Runs the no_deprecated rule.
fn run(
    rule: zlinter.LintRule,
    _: zlinter.LintContext,
    doc: zlinter.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.LintOptions,
) error{OutOfMemory}!?zlinter.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const handle = doc.handle;
    const tree = doc.handle.tree;

    var arena_mem: [32 * 1024]u8 = undefined;
    var arena_buffer = std.heap.FixedBufferAllocator.init(&arena_mem);
    const arena = arena_buffer.allocator();

    var node: zlinter.shims.NodeIndexShim = .init(0);
    while (node.index < handle.tree.nodes.len) : (node.index += 1) {
        defer arena_buffer.reset();

        const tag = zlinter.shims.nodeTag(tree, node.toNodeIndex());
        switch (tag) {
            .enum_literal => try handleEnumLiteral(
                rule,
                gpa,
                arena,
                doc,
                node.toNodeIndex(),
                zlinter.shims.nodeMainToken(tree, node.toNodeIndex()),
                &lint_problems,
            ),
            .field_access => try handleFieldAccess(
                rule,
                gpa,
                arena,
                doc,
                node.toNodeIndex(),
                switch (zlinter.version.zig) {
                    .@"0.14" => zlinter.shims.nodeData(tree, node.toNodeIndex()).rhs,
                    .@"0.15" => zlinter.shims.nodeData(tree, node.toNodeIndex()).node_and_token.@"1",
                },
                &lint_problems,
            ),
            .identifier => try handleVarAccess(
                rule,
                gpa,
                arena,
                doc,
                node.toNodeIndex(),
                zlinter.shims.nodeMainToken(tree, node.toNodeIndex()),
                &lint_problems,
            ),
            else => continue,
        }
    }

    for (lint_problems.items) |*problem| {
        problem.severity = config.severity;
    }

    return if (lint_problems.items.len > 0)
        try zlinter.LintResult.init(
            gpa,
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

fn getLintProblemLocationStart(doc: zlinter.LintDocument, node_index: std.zig.Ast.Node.Index) zlinter.LintProblemLocation {
    const first_token = doc.handle.tree.firstToken(node_index);
    const first_token_loc = doc.handle.tree.tokenLocation(0, first_token);
    return .{
        .offset = first_token_loc.line_start,
        .line = first_token_loc.line,
        .column = first_token_loc.column,
    };
}

fn getLintProblemLocationEnd(doc: zlinter.LintDocument, node_index: std.zig.Ast.Node.Index) zlinter.LintProblemLocation {
    const last_token = doc.handle.tree.lastToken(node_index);
    const last_token_loc = doc.handle.tree.tokenLocation(0, last_token);
    return .{
        .offset = last_token_loc.line_start,
        .line = last_token_loc.line,
        .column = last_token_loc.column + doc.handle.tree.tokenSlice(last_token).len - 1,
    };
}

fn handleVarAccess(
    rule: zlinter.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.LintDocument,
    node_index: std.zig.Ast.Node.Index,
    identifier_token: std.zig.Ast.TokenIndex,
    lint_problems: *std.ArrayListUnmanaged(zlinter.LintProblem),
) !void {
    const handle = doc.handle;
    const analyser = doc.analyser;
    const tree = doc.handle.tree;

    const source_index = handle.tree.tokens.items(.start)[identifier_token];

    const decl = (try analyser.lookupSymbolGlobal(
        handle,
        tree.tokenSlice(identifier_token),
        source_index,
    )) orelse return;

    if (try decl.docComments(arena)) |comment| {
        if (getDeprecationFromDoc(comment)) |message| {
            try lint_problems.append(gpa, .{
                .start = getLintProblemLocationStart(doc, node_index),
                .end = getLintProblemLocationEnd(doc, node_index),
                .message = try std.fmt.allocPrint(gpa, "Deprecated - {s}", .{message}),
                .rule_id = rule.rule_id,
                .severity = undefined, // Set in `run` before returning result
            });
        }
    }
}

fn handleEnumLiteral(
    rule: zlinter.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.LintDocument,
    node_index: std.zig.Ast.Node.Index,
    identifier_token: std.zig.Ast.TokenIndex,
    lint_problems: *std.ArrayListUnmanaged(zlinter.LintProblem),
) !void {
    const decl = try getSymbolEnumLiteral(
        doc,
        node_index,
        doc.handle.tree.tokenSlice(identifier_token),
        gpa,
    ) orelse return;

    if (try decl.docComments(arena)) |doc_comment| {
        if (getDeprecationFromDoc(doc_comment)) |message| {
            try lint_problems.append(gpa, .{
                .start = getLintProblemLocationStart(doc, node_index),
                .end = getLintProblemLocationEnd(doc, node_index),
                .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{message}),
                .rule_id = rule.rule_id,
                .severity = undefined, // Set in `run` before returning result
            });
        }
    }
}

fn getSymbolEnumLiteral(
    doc: zlinter.LintDocument,
    node: std.zig.Ast.Node.Index,
    name: []const u8,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!?zlinter.zls.Analyser.DeclWithHandle {
    std.debug.assert(zlinter.shims.nodeTag(doc.handle.tree, node) == .enum_literal);

    var ancestors = std.ArrayList(std.zig.Ast.Node.Index).init(gpa);
    defer ancestors.deinit();

    var current = node;
    try ancestors.append(current);
    while (doc.child_to_parent.get(current)) |parent| {
        if (zlinter.shims.NodeIndexShim.init(parent).index == 0) break;
        if (zlinter.shims.isNodeOverlapping(doc.handle.tree, current, parent)) {
            try ancestors.append(parent);
            current = parent;
        } else {
            break;
        }
    }

    return switch (zlinter.version.zig) {
        .@"0.14" => doc.analyser.lookupSymbolFieldInit(
            doc.handle,
            name,
            ancestors.items[0..],
        ),
        .@"0.15" => doc.analyser.lookupSymbolFieldInit(
            doc.handle,
            name,
            ancestors.items[0],
            ancestors.items[1..],
        ),
    };
}

fn handleFieldAccess(
    rule: zlinter.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.LintDocument,
    node_index: std.zig.Ast.Node.Index,
    identifier_token: std.zig.Ast.TokenIndex,
    lint_problems: *std.ArrayListUnmanaged(zlinter.LintProblem),
) !void {
    const handle = doc.handle;
    const analyser = doc.analyser;
    const tree = doc.handle.tree;
    const token_starts = handle.tree.tokens.items(.start);

    const held_loc: std.zig.Token.Loc = loc: {
        const first_token = tree.firstToken(node_index);
        const last_token = tree.lastToken(node_index);

        break :loc .{
            .start = token_starts[first_token],
            .end = token_starts[last_token] + tree.tokenSlice(last_token).len,
        };
    };

    if (try analyser.getSymbolFieldAccesses(
        arena,
        handle,
        token_starts[identifier_token],
        held_loc,
        tree.tokenSlice(identifier_token),
    )) |decls| {
        for (decls) |decl| {
            if (try decl.docComments(arena)) |doc_comment| {
                if (getDeprecationFromDoc(doc_comment)) |message| {
                    try lint_problems.append(gpa, .{
                        .start = getLintProblemLocationStart(doc, node_index),
                        .end = getLintProblemLocationEnd(doc, node_index),
                        .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{message}),
                        .rule_id = rule.rule_id,
                        .severity = undefined, // Set in `run` before returning result
                    });
                }
            }
        }
    }
}

/// Returns a slice of a deprecation notice if one was found.
///
/// Deprecation notices must appear on a single document comment line.
fn getDeprecationFromDoc(doc: []const u8) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, doc, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(
            u8,
            line,
            &std.ascii.whitespace,
        );

        for ([_][]const u8{
            "deprecated:",
            "deprecated;",
            "deprecated,",
            "deprecated.",
            "deprecated ",
            "deprecated-",
        }) |line_prefix| {
            if (doc.len < line_prefix.len) continue;

            if (std.ascii.startsWithIgnoreCase(trimmed, line_prefix)) {
                return std.mem.trim(
                    u8,
                    trimmed[line_prefix.len..],
                    &std.ascii.whitespace,
                );
            }
        }
    }
    return null;
}

test getDeprecationFromDoc {
    try std.testing.expectEqualStrings("", getDeprecationFromDoc("DEPRECATED:").?);
    try std.testing.expectEqualStrings("", getDeprecationFromDoc("deprecated; ").?);
    try std.testing.expectEqualStrings("Hello world", getDeprecationFromDoc("DepreCATED-  Hello world").?);
    try std.testing.expectEqualStrings("Hello world", getDeprecationFromDoc("DEPRECATED  Hello world\nAnother comment").?);
    try std.testing.expectEqualStrings("Hello world", getDeprecationFromDoc("DEPrecated,\t  Hello world  \t  ").?);
    try std.testing.expectEqualStrings("use x instead", getDeprecationFromDoc(" Comment above\n deprecated. use x instead\t  \n Comment underneath").?);

    try std.testing.expectEqual(null, getDeprecationFromDoc(""));
    try std.testing.expectEqual(null, getDeprecationFromDoc("DEPRECATE: "));
    try std.testing.expectEqual(null, getDeprecationFromDoc("deprecatttteeeedddd: "));
    try std.testing.expectEqual(null, getDeprecationFromDoc(" "));
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
