//! Enforces that references aren't deprecated (i.e., doc commented with `Deprecated: `)
//!
//! If you're indefinitely targetting fixed versions of a dependency or zig
//! then using deprecated items may not be a big deal. Although, it's still
//! worth undertsanding why they're deprecated, as there may be risks associated
//! with use.

/// Config for no_deprecated rule.
pub const Config = struct {
    /// The severity of deprecations (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_deprecated rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_deprecated),
        .run = &run,
    };
}

/// Runs the no_deprecated rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const handle = doc.handle;
    const tree = doc.handle.tree;

    var arena_mem: [32 * 1024]u8 = undefined;
    var arena_buffer = std.heap.FixedBufferAllocator.init(&arena_mem);
    const arena = arena_buffer.allocator();

    var node: zlinter.shims.NodeIndexShim = .root;
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
                config,
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
                config,
            ),
            .identifier => try handleIdentifierAccess(
                rule,
                gpa,
                arena,
                doc,
                node.toNodeIndex(),
                zlinter.shims.nodeMainToken(tree, node.toNodeIndex()),
                &lint_problems,
                config,
            ),
            else => {},
        }
        if (zlinter.version.zig == .@"0.14") {
            switch (tag) {
                // -----------------------------------------------------------------
                // 0.15 breaking changes - Add explicit breaking changes here:
                // -----------------------------------------------------------------
                .@"usingnamespace" => try lint_problems.append(gpa, .{
                    .start = .startOfToken(tree, zlinter.shims.nodeMainToken(tree, node.toNodeIndex())),
                    .end = .endOfToken(tree, zlinter.shims.nodeMainToken(tree, node.toNodeIndex())),
                    .message = try std.fmt.allocPrint(gpa, "Deprecated - `usingnamespace` keyword is removed in 0.15", .{}),
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                }),
                // I don't think await and async were in used in the compiler
                // but for completeness lets include as they were in the AST:
                .@"await" => try lint_problems.append(gpa, .{
                    .start = .startOfNode(tree, node.toNodeIndex()),
                    .end = .endOfNode(tree, node.toNodeIndex()),
                    .message = try std.fmt.allocPrint(gpa, "Deprecated - `await` keyword is removed in 0.15", .{}),
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                }),
                .async_call_one,
                .async_call_one_comma,
                .async_call_comma,
                .async_call,
                => try lint_problems.append(gpa, .{
                    .start = .startOfNode(tree, node.toNodeIndex()),
                    .end = .endOfNode(tree, node.toNodeIndex()),
                    .message = try std.fmt.allocPrint(gpa, "Deprecated - `async` keyword is removed in 0.15", .{}),
                    .rule_id = rule.rule_id,
                    .severity = config.severity,
                }),
                .builtin_call_two,
                .builtin_call_two_comma,
                .builtin_call,
                .builtin_call_comma,
                => {
                    const main_token = zlinter.shims.nodeMainToken(tree, node.toNodeIndex());
                    if (std.mem.eql(u8, tree.tokenSlice(main_token), "@frameSize")) {
                        try lint_problems.append(gpa, .{
                            .start = .startOfNode(tree, node.toNodeIndex()),
                            .end = .endOfNode(tree, node.toNodeIndex()),
                            .message = try std.fmt.allocPrint(gpa, "Deprecated - @frameSize builtin is removed in 0.15", .{}),
                            .rule_id = rule.rule_id,
                            .severity = config.severity,
                        });
                    }
                },
                else => {},
            }
        }
    }

    for (lint_problems.items) |*problem| {
        problem.severity = config.severity;
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

fn getLintProblemLocationStart(doc: zlinter.session.LintDocument, node_index: std.zig.Ast.Node.Index) zlinter.results.LintProblemLocation {
    const first_token = doc.handle.tree.firstToken(node_index);
    const first_token_loc = doc.handle.tree.tokenLocation(0, first_token);
    return .{
        .byte_offset = first_token_loc.line_start,
        .line = first_token_loc.line,
        .column = first_token_loc.column,
    };
}

fn getLintProblemLocationEnd(doc: zlinter.session.LintDocument, node_index: std.zig.Ast.Node.Index) zlinter.results.LintProblemLocation {
    const last_token = doc.handle.tree.lastToken(node_index);
    const last_token_loc = doc.handle.tree.tokenLocation(0, last_token);
    return .{
        .byte_offset = last_token_loc.line_start,
        .line = last_token_loc.line,
        .column = last_token_loc.column + doc.handle.tree.tokenSlice(last_token).len - 1,
    };
}

fn handleIdentifierAccess(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.session.LintDocument,
    node_index: std.zig.Ast.Node.Index,
    identifier_token: std.zig.Ast.TokenIndex,
    lint_problems: *std.ArrayListUnmanaged(zlinter.results.LintProblem),
    config: Config,
) !void {
    const handle = doc.handle;
    const analyser = doc.analyser;
    const tree = doc.handle.tree;

    const source_index = handle.tree.tokens.items(.start)[identifier_token];

    const decl_with_handle = (try analyser.lookupSymbolGlobal(
        handle,
        tree.tokenSlice(identifier_token),
        source_index,
    )) orelse return;

    // Check whether the identifier is itself the declaration, in which case
    // we should skip as its not the usage but the declaration of it and we
    // dont want to list the declaration as deprecated only its usages
    out: {
        if (std.mem.eql(u8, decl_with_handle.handle.uri, handle.uri)) {
            switch (decl_with_handle.decl) {
                .ast_node => |decl_node| {
                    const decl_identifier_token = switch (zlinter.shims.nodeTag(decl_with_handle.handle.tree, decl_node)) {
                        .container_field_init,
                        .container_field_align,
                        .container_field,
                        => zlinter.shims.nodeMainToken(decl_with_handle.handle.tree, decl_node),
                        else => break :out,
                    };
                    if (decl_identifier_token == identifier_token) return;
                },
                .error_token => |err_token| {
                    if (err_token == identifier_token) return;
                },
                else => {},
            }
        }
    }

    if (try decl_with_handle.docComments(arena)) |comment| {
        if (getDeprecationFromDoc(comment)) |message| {
            try lint_problems.append(gpa, .{
                .start = getLintProblemLocationStart(doc, node_index),
                .end = getLintProblemLocationEnd(doc, node_index),
                .message = try std.fmt.allocPrint(gpa, "Deprecated - {s}", .{message}),
                .rule_id = rule.rule_id,
                .severity = config.severity,
            });
        }
    }
}

fn handleEnumLiteral(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.session.LintDocument,
    node_index: std.zig.Ast.Node.Index,
    identifier_token: std.zig.Ast.TokenIndex,
    lint_problems: *std.ArrayListUnmanaged(zlinter.results.LintProblem),
    config: Config,
) !void {
    const decl_with_handle = try getSymbolEnumLiteral(
        doc,
        node_index,
        doc.handle.tree.tokenSlice(identifier_token),
        gpa,
    ) orelse return;

    if (try decl_with_handle.docComments(arena)) |doc_comment| {
        if (getDeprecationFromDoc(doc_comment)) |message| {
            try lint_problems.append(gpa, .{
                .start = getLintProblemLocationStart(doc, node_index),
                .end = getLintProblemLocationEnd(doc, node_index),
                .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{message}),
                .rule_id = rule.rule_id,
                .severity = config.severity,
            });
        }
    }
}

fn getSymbolEnumLiteral(
    doc: zlinter.session.LintDocument,
    node: std.zig.Ast.Node.Index,
    name: []const u8,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!?zlinter.zls.Analyser.DeclWithHandle {
    std.debug.assert(zlinter.shims.nodeTag(doc.handle.tree, node) == .enum_literal);

    var ancestors = std.ArrayList(std.zig.Ast.Node.Index).init(gpa);
    defer ancestors.deinit();

    var current = node;
    try ancestors.append(current);

    var it = doc.nodeAncestorIterator(current);
    while (it.next()) |ancestor| {
        if (zlinter.shims.NodeIndexShim.init(ancestor).isRoot()) break;
        if (zlinter.shims.isNodeOverlapping(doc.handle.tree, current, ancestor)) {
            try ancestors.append(ancestor);
            current = ancestor;
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
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.session.LintDocument,
    node_index: std.zig.Ast.Node.Index,
    identifier_token: std.zig.Ast.TokenIndex,
    lint_problems: *std.ArrayListUnmanaged(zlinter.results.LintProblem),
    config: Config,
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
                        .severity = config.severity,
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

test "no_deprecated - regression test for #36" {
    const source: [:0]const u8 =
        \\const convention: namespace.CallingConvention = .Stdcall;
        \\
        \\const namespace = struct {
        \\  const CallingConvention = enum {
        \\    /// Deprecated: Don't use
        \\    Stdcall,
        \\    std_call,
        \\  };
        \\};
    ;

    const rule = buildRule(.{});
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/regression_36.zig"),
        source,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/regression_36.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .start = .{
                    .byte_offset = 0,
                    .line = 0,
                    .column = 48,
                },
                .end = .{
                    .byte_offset = 0,
                    .line = 0,
                    .column = 55,
                },
                .message = "Deprecated: Don't use",
            },
        },
        result.problems,
    );
}

test "no_deprecated - explicit 0.15.x breaking changes" {
    if (zlinter.version.zig != .@"0.14") return error.SkipZigTest;

    const source: [:0]const u8 =
        \\
        \\pub usingnamespace @import("something");
        \\
        \\fn func3() u32 {
        \\  return @frameSize(u32);
        \\}
        \\
        \\test "async / await" {
        \\  var frame = async func3();
        \\  try expect(await frame == 5);
        \\}
    ;

    const rule = buildRule(.{});
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/removed_features.zig"),
        source,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/removed_features.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .start = .{
                    .byte_offset = 5,
                    .line = 1,
                    .column = 4,
                },
                .end = .{
                    .byte_offset = 18,
                    .line = 1,
                    .column = 17,
                },
                .message = "Deprecated - `usingnamespace` keyword is removed in 0.15",
            },
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .start = .{
                    .byte_offset = 69,
                    .line = 4,
                    .column = 9,
                },
                .end = .{
                    .byte_offset = 84,
                    .line = 4,
                    .column = 24,
                },
                .message = "Deprecated - @frameSize builtin is removed in 0.15",
            },
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .start = .{
                    .byte_offset = 126,
                    .line = 8,
                    .column = 14,
                },
                .end = .{
                    .byte_offset = 139,
                    .line = 8,
                    .column = 27,
                },
                .message = "Deprecated - `async` keyword is removed in 0.15",
            },
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .start = .{
                    .byte_offset = 154,
                    .line = 9,
                    .column = 13,
                },
                .end = .{
                    .byte_offset = 165,
                    .line = 9,
                    .column = 24,
                },
                .message = "Deprecated - `await` keyword is removed in 0.15",
            },
        },
        result.problems,
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
