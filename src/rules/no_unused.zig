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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.container_declaration == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);
    const token_tags = tree.tokens.items(.tag);

    // Store an index of referenced identifiers and field accesses on the
    // container, this is then used to check whether a root declaration is
    // being used.
    var container_references = map: {
        var map: std.StringHashMapUnmanaged(void) = .empty;

        var index: u32 = @intFromEnum(Ast.Node.Index.root);
        while (index < tree.nodes.len) : (index += 1) {
            const node: Ast.Node.Index = @enumFromInt(index);
            switch (tree.nodeTag(node)) {
                .identifier => try map.put(
                    rule_arena,
                    tree.tokenSlice(tree.nodeMainToken(node)),
                    {},
                ),
                .field_access => if (referencedDeclName(session, doc, rule_arena, node)) |name|
                    try map.put(rule_arena, name, {}),
                else => {},
            }
        }
        break :map map;
    };

    for (tree.rootDecls()) |decl| {
        const problem: ?struct { first: Ast.TokenIndex, last: Ast.TokenIndex } = problem: {
            if (tree.fullVarDecl(decl)) |var_decl| {
                if (zlinter.ast.varDeclVisibility(tree, var_decl) == .public)
                    break :problem null;

                if (var_decl.extern_export_token) |extern_export_token|
                    if (token_tags[extern_export_token] == .keyword_export)
                        break :problem null;

                if (!container_references.contains(tree.tokenSlice(var_decl.ast.mut_token + 1)))
                    break :problem .{
                        .first = tree.firstToken(decl),
                        .last = tree.lastToken(decl) + 1, // "+ 1" to consume the semicolon for this statement
                    };
            } else {
                var buffer: [1]Ast.Node.Index = undefined;
                if (namedFnDeclProto(tree, &buffer, decl)) |fn_proto| {
                    if (zlinter.ast.fnProtoVisibility(tree, fn_proto) == .public) break :problem null;

                    if (fn_proto.extern_export_inline_token) |token|
                        if (token_tags[token] == .keyword_export)
                            break :problem null;

                    if (!container_references.contains(tree.tokenSlice(fn_proto.name_token.?)))
                        break :problem .{
                            .first = tree.firstToken(decl),
                            .last = tree.lastToken(decl),
                        };
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

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.container_declaration,
                .start = .startOfToken(tree, first_token),
                .end = .endOfToken(tree, last_token),
                .message = try session_arena.dupe(u8, "Unused declaration"),
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
            session_arena,
            doc.absPath(session),
            lint_problems.items,
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
    if (switch (tree.nodeTag(node)) {
        .fn_decl => tree.fullFnProto(
            buffer,
            tree.nodeData(node).node_and_node.@"0",
        ),
        else => null,
    }) |fn_proto| {
        if (fn_proto.name_token != null) return fn_proto;
    }
    return null;
}

fn referencedDeclName(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    node: Ast.Node.Index,
) ?[]const u8 {
    const tree = doc.tree(session);
    std.debug.assert(tree.nodeTag(node) == .field_access);

    {
        var decl_candidates = session.resolveDeclCandidatesOfNode(allocator, doc, node) catch return null;
        defer decl_candidates.deinit(allocator);
        for (decl_candidates.items) |candidate| {
            if (session.decl_store.declFileId(candidate.decl_id) != doc.file_id)
                continue;

            const name_token = session.decl_store.declNameToken(candidate.decl_id) orelse continue;
            return tree.tokenSlice(name_token);
        }
    }

    const lhs, const member_token = tree.nodeData(node).node_and_token;
    const member_name = tree.tokenSlice(member_token);

    if (isCallCallee(tree, doc, node)) {
        const root_decl_id = session.decl_store.rootDecl(doc.file_id) orelse return null;
        var member_candidates = session.resolveDeclMemberCandidates(
            allocator,
            root_decl_id,
            member_name,
        ) catch return null;
        defer member_candidates.deinit(allocator);
        for (member_candidates.items) |candidate| {
            const decl_id = candidate.decl_id;
            if (session.decl_store.declFileId(decl_id) != doc.file_id)
                continue;

            const name_token = session.decl_store.declNameToken(decl_id) orelse return null;
            return tree.tokenSlice(name_token);
        }
    }

    {
        var type_candidates = session.resolveTypeCandidatesOfNode(allocator, doc, lhs) catch return null;
        defer type_candidates.deinit(allocator);
        if (session.decl_store.rootDecl(doc.file_id)) |root_decl_id| {
            for (type_candidates.items) |candidate| {
                if (candidate.type.decl_id == root_decl_id)
                    return member_name;
            }
        }
    }
    return null;
}

fn isCallCallee(
    tree: Ast,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
) bool {
    var ancestors = doc.nodeAncestorIterator(node);
    const parent = ancestors.next() orelse return false;

    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, parent) orelse
        return false;
    return call.ast.fn_expr == node;
}

test "no_unused" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
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
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .container_declaration = severity },
            &.{
                .{
                    .rule_id = "no_unused",
                    .severity = severity,
                    .slice =
                    \\const a = @import("a");
                    ,
                    .message = "Unused declaration",
                    .fix = .{
                        .start = 1,
                        .end = 25,
                        .text = "",
                    },
                },
                .{
                    .rule_id = "no_unused",
                    .severity = severity,
                    .slice =
                    \\var Ok = struct {
                    \\ name: u32,
                    \\};
                    ,
                    .message = "Unused declaration",
                    .fix = .{
                        .start = 53,
                        .end = 86,
                        .text = "",
                    },
                },
                .{
                    .rule_id = "no_unused",
                    .severity = severity,
                    .slice =
                    \\fn unusedFn() void {
                    \\   usedFn();
                    \\}
                    ,
                    .message = "Unused declaration",
                    .fix = .{
                        .start = 107,
                        .end = 142,
                        .text = "",
                    },
                },
            },
        );
    }

    // Off
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .container_declaration = .off },
        &.{},
    );

    // Root through @This()
    try zlinter.testing.testRunRule(
        rule,
        \\const used_by_root_field = 123;
        \\
        \\pub fn main() void {
        \\    _ = @This().used_by_root_field;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    // Root through reference
    try zlinter.testing.testRunRule(
        rule,
        \\const Self = @This();
        \\const used_by_root_field = 123;
        \\
        \\pub fn main() void {
        \\    _ = Self.used_by_root_field;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    // Method-style field access on a same-file type.
    try zlinter.testing.testRunRule(
        rule,
        \\const Store = @This();
        \\
        \\pub fn main(store: *Store) void {
        \\    store.used();
        \\}
        \\
        \\fn used(self: *Store) void {
        \\    _ = self;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
