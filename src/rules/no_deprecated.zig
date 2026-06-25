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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < doc.tree(session).nodes.len) : (index += 1) {
        const tree = doc.tree(session);
        const node: Ast.Node.Index = @enumFromInt(index);
        const tag = tree.nodeTag(node);

        var struct_init_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
            try handleStructInit(
                rule,
                session_arena,
                rule_arena,
                session,
                doc,
                node,
                struct_init,
                &lint_problems,
                config,
            );
        }

        switch (tag) {
            .enum_literal => try handleEnumLiteral(
                rule,
                session_arena,
                rule_arena,
                session,
                doc,
                node,
                tree.nodeMainToken(node),
                &lint_problems,
                config,
            ),
            .field_access => try handleFieldAccess(
                rule,
                session_arena,
                rule_arena,
                session,
                doc,
                node,
                tree.nodeData(node).node_and_token.@"1",
                &lint_problems,
                config,
            ),
            .identifier => try handleIdentifierAccess(
                rule,
                session_arena,
                rule_arena,
                session,
                doc,
                node,
                tree.nodeMainToken(node),
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
            session_arena,
            doc.absPath(session),
            lint_problems.items,
        )
    else
        null;
}

fn handleStructInit(
    rule: zlinter.rules.LintRule,
    session_arena: std.mem.Allocator,
    rule_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    const tree = doc.tree(session);
    const struct_candidates = try resolveStructInitTypeDeclCandidates(
        session,
        rule_arena,
        doc,
        node_index,
        struct_init,
    );

    for (struct_init.ast.fields) |field_node| {
        const field_name_token = structInitFieldNameTokenFromField(
            tree,
            field_node,
        ) orelse
            continue;

        const field_candidates = try session.resolveDeclMemberCandidatesFromCandidates(
            rule_arena,
            struct_candidates.items,
            tree.tokenSlice(field_name_token),
        );

        for (field_candidates.items) |candidate| {
            const doc_comment = try session.allocDeclDocComments(
                rule_arena,
                candidate.decl_id,
            ) orelse
                continue;
            const deprecated_message = getDeprecationFromDoc(doc_comment) orelse continue;
            const notes = try allocDeprecatedDeclNotes(
                session_arena,
                session,
                candidate.decl_id,
            );

            try lint_problems.append(session_arena, .{
                .start = .startOfToken(tree, field_name_token),
                .end = .endOfToken(tree, field_name_token),
                .message = try std.fmt.allocPrint(
                    session_arena,
                    "Deprecated: {s}",
                    .{deprecated_message},
                ),
                .notes = notes,
                .rule_id = rule.rule_id,
                .severity = config.severity,
            });
        }
    }
}

fn handleIdentifierAccess(
    rule: zlinter.rules.LintRule,
    session_arena: std.mem.Allocator,
    rule_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    const tree = doc.tree(session);

    const decl_candidates = try session.resolveDeclCandidatesOfNode(rule_arena, doc, node_index);
    for (decl_candidates.items) |candidate| {
        // Check whether the identifier is itself the declaration, in which case
        // we should skip as its not the usage but the declaration of it and we
        // dont want to list the declaration as deprecated only its usages
        if (session.decl_store.declFileId(candidate.decl_id) == doc.file_id) {
            if (session.decl_store.declNameToken(candidate.decl_id)) |name_token| {
                if (name_token == identifier_token) continue;
            }
        }

        try appendDeprecatedProblem(
            rule,
            session_arena,
            rule_arena,
            session,
            tree,
            node_index,
            candidate.decl_id,
            "Deprecated: {s}",
            lint_problems,
            config,
        );
    }
}

fn handleEnumLiteral(
    rule: zlinter.rules.LintRule,
    session_arena: std.mem.Allocator,
    rule_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    const tree = doc.tree(session);
    const decl_candidates = try resolveEnumLiteralDeclCandidates(
        session,
        rule_arena,
        doc,
        node_index,
        tree.tokenSlice(identifier_token),
    );
    for (decl_candidates.items) |candidate| {
        try appendDeprecatedProblem(
            rule,
            session_arena,
            rule_arena,
            session,
            tree,
            node_index,
            candidate.decl_id,
            "Deprecated: {s}",
            lint_problems,
            config,
        );
    }
}

fn handleFieldAccess(
    rule: zlinter.rules.LintRule,
    session_arena: std.mem.Allocator,
    rule_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    const tree = doc.tree(session);
    _ = identifier_token;

    const decl_candidates = try session.resolveDeclCandidatesOfNode(rule_arena, doc, node_index);
    for (decl_candidates.items) |candidate| {
        try appendDeprecatedProblem(
            rule,
            session_arena,
            rule_arena,
            session,
            tree,
            node_index,
            candidate.decl_id,
            "Deprecated: {s}",
            lint_problems,
            config,
        );
    }
}

fn appendDeprecatedProblem(
    rule: zlinter.rules.LintRule,
    session_arena: std.mem.Allocator,
    rule_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    tree: Ast,
    node_index: Ast.Node.Index,
    decl_id: zlinter.session.DeclStore.DeclId,
    comptime message_fmt: []const u8,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    const doc_comment = try session.allocDeclDocComments(rule_arena, decl_id) orelse return;
    const deprecated_message = getDeprecationFromDoc(doc_comment) orelse return;
    const notes = try allocDeprecatedDeclNotes(session_arena, session, decl_id);

    try lint_problems.append(session_arena, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(session_arena, message_fmt, .{deprecated_message}),
        .notes = notes,
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

fn allocDeprecatedDeclNotes(
    session_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    decl_id: zlinter.session.DeclStore.DeclId,
) !?[]zlinter.results.LintProblemNote {
    const decl_location = session.declLocation(decl_id) orelse return null;

    const notes = try session_arena.alloc(zlinter.results.LintProblemNote, 1);
    notes[0] = .{
        .abs_path = try session_arena.dupe(u8, decl_location.abs_path),
        .start = decl_location.start,
        .end = decl_location.end,
        .line = decl_location.line,
        .column = decl_location.column,
        .message = try session_arena.dupe(u8, "deprecated declaration is here"),
    };
    return notes;
}

fn resolveEnumLiteralDeclCandidates(
    session: *zlinter.session.LintSession,
    rule_arena: std.mem.Allocator,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    name: []const u8,
) !std.ArrayList(zlinter.session.LintSession.DeclCandidate) {
    const enum_candidates = try resolveEnumLiteralContextTypeDeclCandidates(
        session,
        rule_arena,
        doc,
        node,
    );

    return session.resolveDeclMemberCandidatesFromCandidates(
        rule_arena,
        enum_candidates.items,
        name,
    );
}

fn resolveStructInitTypeDeclCandidates(
    session: *zlinter.session.LintSession,
    rule_arena: std.mem.Allocator,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    struct_init: Ast.full.StructInit,
) !std.ArrayList(zlinter.session.LintSession.DeclCandidate) {
    if (struct_init.ast.type_expr.unwrap()) |type_expr|
        return session.resolveDeclCandidatesOfNode(rule_arena, doc, type_expr);

    return resolveEnumLiteralContextTypeDeclCandidates(
        session,
        rule_arena,
        doc,
        node,
    );
}

fn resolveEnumLiteralContextTypeDeclCandidates(
    session: *zlinter.session.LintSession,
    rule_arena: std.mem.Allocator,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
) !std.ArrayList(zlinter.session.LintSession.DeclCandidate) {
    const tree = doc.tree(session);

    var struct_init_buffer: [2]Ast.Node.Index = undefined;
    var current = node;
    var it = doc.nodeAncestorIterator(current);
    while (it.next()) |ancestor| {
        if (ancestor == .root) break;

        if (tree.fullStructInit(&struct_init_buffer, ancestor)) |struct_init| {
            if (structInitFieldNameToken(tree, struct_init, current)) |field_name_token| {
                const struct_candidates = if (struct_init.ast.type_expr.unwrap()) |type_expr|
                    try session.resolveDeclCandidatesOfNode(rule_arena, doc, type_expr)
                else
                    try resolveEnumLiteralContextTypeDeclCandidates(
                        session,
                        rule_arena,
                        doc,
                        ancestor,
                    );

                const field_candidates = try session.resolveDeclMemberCandidatesFromCandidates(
                    rule_arena,
                    struct_candidates.items,
                    tree.tokenSlice(field_name_token),
                );

                return session.resolveDeclTypeDeclCandidatesFromCandidates(
                    rule_arena,
                    field_candidates.items,
                );
            }
        }

        if (tree.fullVarDecl(ancestor)) |var_decl| {
            const init_node = var_decl.ast.init_node.unwrap() orelse {
                current = ancestor;
                continue;
            };
            if (nodeWithin(tree, init_node, current)) {
                const decl_id = session.decl_store.declIdByNode(doc.file_id, ancestor) orelse return .empty;
                return session.resolveDeclTypeDeclCandidates(rule_arena, decl_id);
            }
        }

        if (tree.fullContainerField(ancestor)) |field| {
            const value_node = field.ast.value_expr.unwrap() orelse {
                current = ancestor;
                continue;
            };
            if (nodeWithin(tree, value_node, current)) {
                const decl_id = session.decl_store.declIdByNode(doc.file_id, ancestor) orelse return .empty;
                return session.resolveDeclTypeDeclCandidates(rule_arena, decl_id);
            }
        }

        current = ancestor;
    }

    return .empty;
}

fn structInitFieldNameToken(
    tree: Ast,
    struct_init: Ast.full.StructInit,
    node: Ast.Node.Index,
) ?Ast.TokenIndex {
    for (struct_init.ast.fields) |field_node| {
        if (!nodeWithin(tree, field_node, node)) continue;

        return structInitFieldNameTokenFromField(
            tree,
            field_node,
        );
    }
    return null;
}

fn structInitFieldNameTokenFromField(
    tree: Ast,
    field_node: Ast.Node.Index,
) ?Ast.TokenIndex {
    const field_first_token = tree.firstToken(field_node);
    if (field_first_token < 2) return null;

    const field_name_token = field_first_token - 2;
    if (tree.tokenTag(field_name_token) != .identifier) return null;
    if (tree.tokenTag(field_name_token - 1) != .period) return null;
    return field_name_token;
}

fn nodeWithin(tree: Ast, container: Ast.Node.Index, node: Ast.Node.Index) bool {
    return container == node or ast.isNodeOverlapping(tree, container, node);
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

test "no_deprecated - identifier diagnostic uses colon prefix consistently" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\/// Deprecated: use replacement instead
        \\const old_name = 1;
        \\
        \\const value = old_name;
    ,
        .{},
        Config{ .severity = .warning },
        &.{
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .slice = "old_name",
                .message = "Deprecated: use replacement instead",
            },
        },
    );
}

test "no_deprecated - reports deprecated struct init field designators" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const S = struct {
        \\    /// Deprecated: use new
        \\    old: u32 = 0,
        \\    new: u32 = 0,
        \\};
        \\
        \\const x = S{ .old = 1 };
    ,
        .{},
        Config{ .severity = .warning },
        &.{
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .slice = "old",
                .message = "Deprecated: use new",
            },
        },
    );
}

test "no_deprecated - ignores non-deprecated and unknown struct init field designators" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const S = struct {
        \\    /// Deprecated: use new
        \\    old: u32 = 0,
        \\    new: u32 = 0,
        \\};
        \\
        \\const x = S{ .new = 1 };
        \\const y = S{ .missing = 1 };
    ,
        .{},
        Config{ .severity = .warning },
        &.{},
    );
}

test "no_deprecated - reports deprecated inferred struct init field designators" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const S = struct {
        \\    /// Deprecated: use new
        \\    old: u32 = 0,
        \\    new: u32 = 0,
        \\};
        \\
        \\const x: S = .{ .old = 1 };
    ,
        .{},
        Config{ .severity = .warning },
        &.{
            .{
                .rule_id = "no_deprecated",
                .severity = .warning,
                .slice = "old",
                .message = "Deprecated: use new",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const ast = zlinter.ast;
const Ast = std.zig.Ast;
