//! Enforces that references aren't deprecated (i.e., doc commented with `Deprecated:`)
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
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var resolver = try NativeResolver.init(context, doc, gpa, arena);
    defer resolver.deinit(gpa);

    const tree = doc.handle.tree;
    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        defer _ = arena_allocator.reset(.retain_capacity);

        const node: Ast.Node.Index = @enumFromInt(index);
        const tag = tree.nodeTag(node);
        switch (tag) {
            .enum_literal => try handleEnumLiteral(
                rule,
                gpa,
                arena,
                &resolver,
                doc,
                node,
                &lint_problems,
                config,
            ),
            .field_access => try handleFieldAccess(
                rule,
                gpa,
                arena,
                &resolver,
                doc,
                node,
                &lint_problems,
                config,
            ),
            .identifier => try handleIdentifierAccess(
                rule,
                gpa,
                arena,
                &resolver,
                doc,
                node,
                &lint_problems,
                config,
            ),
            else => {},
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
    resolver: *NativeResolver,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    _ = arena;
    const tree = doc.handle.tree;
    const identifier_token = tree.nodeMainToken(node_index);

    // Skip declaration identifiers; only usage sites should be reported.
    if (isIdentifierDeclarationSite(doc, node_index, identifier_token)) return;

    const source_index = tree.tokens.items(.start)[identifier_token];
    const resolved = resolver.resolveExpr(doc, node_index, source_index, 0) orelse return;
    const deprecated_message = deprecatedMessageFromResolved(resolver, resolved, gpa) orelse return;
    defer gpa.free(deprecated_message);

    try lint_problems.append(gpa, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated - {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

fn handleEnumLiteral(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    resolver: *NativeResolver,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    _ = arena;
    const tree = doc.handle.tree;
    const tag_name = tree.tokenSlice(tree.nodeMainToken(node_index));
    const source_index = tree.tokens.items(.start)[tree.nodeMainToken(node_index)];

    const enum_container = resolver.resolveEnumContainerForLiteral(doc, node_index, source_index, 0) orelse return;
    const member = resolver.resolveContainerMember(enum_container, tag_name) orelse return;
    const deprecated_message = deprecatedMessageFromDecl(resolver, member, gpa) orelse return;
    defer gpa.free(deprecated_message);

    try lint_problems.append(gpa, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

fn handleFieldAccess(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    resolver: *NativeResolver,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    _ = arena;
    const tree = doc.handle.tree;
    const source_index = tree.tokens.items(.start)[tree.firstToken(node_index)];
    const resolved = resolver.resolveExpr(doc, node_index, source_index, 0) orelse return;
    const deprecated_message = deprecatedMessageFromResolved(resolver, resolved, gpa) orelse return;
    defer gpa.free(deprecated_message);

    try lint_problems.append(gpa, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

const NativeResolver = semantic_resolver.Resolver;

fn deprecatedMessageFromResolved(
    resolver: *NativeResolver,
    resolved: NativeResolver.ResolvedRef,
    gpa: std.mem.Allocator,
) ?[]const u8 {
    const doc_text = resolver.docCommentTextForResolved(resolved) orelse return null;
    defer gpa.free(doc_text);
    return if (getDeprecationFromDoc(doc_text)) |dep|
        gpa.dupe(u8, dep) catch null
    else
        null;
}

fn deprecatedMessageFromDecl(
    resolver: *NativeResolver,
    decl: NativeResolver.DeclRef,
    gpa: std.mem.Allocator,
) ?[]const u8 {
    const doc_text = resolver.docCommentTextForDecl(decl) orelse return null;
    defer gpa.free(doc_text);
    return if (getDeprecationFromDoc(doc_text)) |dep|
        gpa.dupe(u8, dep) catch null
    else
        null;
}

fn isIdentifierDeclarationSite(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
) bool {
    const tree = doc.handle.tree;
    var current = node;
    while (doc.lineage.items(.parent)[@intFromEnum(current)]) |parent| {
        current = parent;
        if (tree.fullVarDecl(current)) |var_decl| {
            return var_decl.ast.mut_token + 1 == identifier_token;
        }
        if (tree.nodeTag(current) == .fn_decl) {
            var fn_proto_buffer: [1]Ast.Node.Index = undefined;
            const fn_decl = zlinter.ast.fnDecl(tree, current, &fn_proto_buffer) orelse return false;
            return fn_decl.proto.name_token != null and fn_decl.proto.name_token.? == identifier_token;
        }
        if (tree.fullContainerField(current)) |field| {
            const name_token = field.ast.main_token;
            return name_token == identifier_token;
        }
    }
    return false;
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
                .slice = ".Stdcall",
                .message = "Deprecated: Don't use",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const semantic_resolver = zlinter.semantic_resolver;
const Ast = std.zig.Ast;
