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
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_deprecated),
        .run = &run,
    };
}

/// Runs the no_deprecated rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const handle = doc.handle;
    const tree = doc.handle.tree;

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var node: NodeIndexShim = .root;
    while (node.index < handle.tree.nodes.len) : (node.index += 1) {
        defer _ = arena_allocator.reset(.retain_capacity);

        const tag = shims.nodeTag(tree, node.toNodeIndex());
        switch (tag) {
            .enum_literal => try handleEnumLiteral(
                rule,
                gpa,
                arena,
                doc,
                node.toNodeIndex(),
                shims.nodeMainToken(tree, node.toNodeIndex()),
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
                    .@"0.14" => shims.nodeData(tree, node.toNodeIndex()).rhs,
                    .@"0.15", .@"0.16" => shims.nodeData(tree, node.toNodeIndex()).node_and_token.@"1",
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
                shims.nodeMainToken(tree, node.toNodeIndex()),
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
                    .start = .startOfToken(tree, shims.nodeMainToken(tree, node.toNodeIndex())),
                    .end = .endOfToken(tree, shims.nodeMainToken(tree, node.toNodeIndex())),
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
                    const main_token = shims.nodeMainToken(tree, node.toNodeIndex());
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

fn handleIdentifierAccess(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    doc: zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
    lint_problems: *shims.ArrayList(zlinter.results.LintProblem),
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
    if (std.mem.eql(u8, decl_with_handle.handle.uri, handle.uri)) {
        const is_identifier = switch (decl_with_handle.decl) {
            .ast_node => |decl_node| switch (shims.nodeTag(decl_with_handle.handle.tree, decl_node)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => shims.nodeMainToken(decl_with_handle.handle.tree, decl_node) == identifier_token,
                else => false,
            },
            .error_token => |err_token| err_token == identifier_token,
            else => false,
        };
        if (is_identifier) return;
    }

    if (try decl_with_handle.docComments(arena)) |comment| {
        if (getDeprecationFromDoc(comment)) |message| {
            try lint_problems.append(gpa, .{
                .start = .startOfNode(doc.handle.tree, node_index),
                .end = .endOfNode(doc.handle.tree, node_index),
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
    node_index: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
    lint_problems: *shims.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    const decl_with_handle = try getSymbolEnumLiteral(
        doc,
        node_index,
        doc.handle.tree.tokenSlice(identifier_token),
        gpa,
    ) orelse return;

    const doc_comment = try decl_with_handle.docComments(arena) orelse return;
    const deprecated_message = getDeprecationFromDoc(doc_comment) orelse return;

    try lint_problems.append(gpa, .{
        .start = .startOfNode(doc.handle.tree, node_index),
        .end = .endOfNode(doc.handle.tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

fn getSymbolEnumLiteral(
    doc: zlinter.session.LintDocument,
    node: Ast.Node.Index,
    name: []const u8,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!?zlinter.zls.Analyser.DeclWithHandle {
    std.debug.assert(shims.nodeTag(doc.handle.tree, node) == .enum_literal);

    var ancestors = shims.ArrayList(Ast.Node.Index).empty;
    defer ancestors.deinit(gpa);

    var current = node;
    try ancestors.append(gpa, current);

    var it = doc.nodeAncestorIterator(current);
    while (it.next()) |ancestor| {
        if (NodeIndexShim.init(ancestor).isRoot()) break;
        if (shims.isNodeOverlapping(doc.handle.tree, current, ancestor)) {
            try ancestors.append(gpa, ancestor);
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
        .@"0.15", .@"0.16" => doc.analyser.lookupSymbolFieldInit(
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
    node_index: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
    lint_problems: *shims.ArrayList(zlinter.results.LintProblem),
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
            const doc_comment = try decl.docComments(arena) orelse continue;
            const deprecated_message = getDeprecationFromDoc(doc_comment) orelse continue;

            try lint_problems.append(gpa, .{
                .start = .startOfNode(doc.handle.tree, node_index),
                .end = .endOfNode(doc.handle.tree, node_index),
                .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{deprecated_message}),
                .rule_id = rule.rule_id,
                .severity = config.severity,
            });
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
            if (!std.ascii.startsWithIgnoreCase(trimmed, line_prefix)) continue;

            return std.mem.trim(
                u8,
                trimmed[line_prefix.len..],
                &std.ascii.whitespace,
            );
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
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const convention: namespace.CallingConvention = .Stdcall;
        \\
        \\const namespace = struct {
        \\  const CallingConvention = enum {
        \\    /// Deprecated: Don't use
        \\    Stdcall,
        \\    std_call,
        \\  };
        \\};
    ,
        .{},
        Config{ .severity = .@"error" },
        &.{
            .{
                .rule_id = "no_deprecated",
                .severity = .@"error",
                .slice = ".Stdcall;",
                .message = "Deprecated: Don't use",
            },
        },
    );
}

test "no_deprecated - explicit 0.15.x breaking changes" {
    if (zlinter.version.zig != .@"0.14") return error.SkipZigTest;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
    ,
        .{},
        Config{ .severity = .@"error" },
        &.{
            .{
                .rule_id = "no_deprecated",
                .severity = .@"error",
                .slice = "usingnamespace",
                .message = "Deprecated - `usingnamespace` keyword is removed in 0.15",
            },
            .{
                .rule_id = "no_deprecated",
                .severity = .@"error",
                .slice = "@frameSize(u32);",
                .message = "Deprecated - @frameSize builtin is removed in 0.15",
            },
            .{
                .rule_id = "no_deprecated",
                .severity = .@"error",
                .slice = "async func3();",
                .message = "Deprecated - `async` keyword is removed in 0.15",
            },
            .{
                .rule_id = "no_deprecated",
                .severity = .@"error",
                .slice = "await frame ",
                .message = "Deprecated - `await` keyword is removed in 0.15",
            },
        },
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
