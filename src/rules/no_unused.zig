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

    // Store referenced identifiers and field accesses on the container with
    // their source locations. This lets a declaration ignore references from
    // inside its own body (i.e., recursive calls).
    const container_references = map: {
        var references = std.ArrayList(DeclReference).empty;

        var index: u32 = @intFromEnum(Ast.Node.Index.root);
        while (index < tree.nodes.len) : (index += 1) {
            const node: Ast.Node.Index = @enumFromInt(index);
            switch (tree.nodeTag(node)) {
                .identifier => try references.append(rule_arena, .{
                    .name = tree.tokenSlice(tree.nodeMainToken(node)),
                    .node = node,
                    .token = tree.nodeMainToken(node),
                }),
                .field_access => if (referencedDeclReference(
                    session,
                    doc,
                    rule_arena,
                    node,
                )) |reference|
                    try references.append(rule_arena, reference),
                else => {},
            }
        }
        break :map references;
    };

    const candidate_decls = try containerDeclarationCandidates(
        rule_arena,
        tree,
        token_tags,
        container_references.items,
    );

    for (candidate_decls.items) |decl| {
        const problem = unusedDeclarationProblem(
            tree,
            token_tags,
            container_references.items,
            decl,
        );

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

const DeclReference = struct {
    name: []const u8,
    node: Ast.Node.Index,
    token: Ast.TokenIndex,
};

const DeclarationProblem = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
};

fn containerDeclarationCandidates(
    allocator: std.mem.Allocator,
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: []const DeclReference,
) !std.ArrayList(Ast.Node.Index) {
    var candidates = std.ArrayList(Ast.Node.Index).empty;
    try appendContainerDeclarationCandidates(
        allocator,
        tree,
        token_tags,
        references,
        tree.rootDecls(),
        &candidates,
    );
    return candidates;
}

fn appendContainerDeclarationCandidates(
    allocator: std.mem.Allocator,
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: []const DeclReference,
    members: []const Ast.Node.Index,
    candidates: *std.ArrayList(Ast.Node.Index),
) !void {
    for (members) |member| {
        try candidates.append(allocator, member);

        if (!shouldDescendIntoDeclaration(
            tree,
            token_tags,
            references,
            member,
        ))
            continue;

        const container_node = declarationContainerNode(
            tree,
            member,
        ) orelse
            continue;

        var buffer: [2]Ast.Node.Index = undefined;
        const container_decl = tree.fullContainerDecl(
            &buffer,
            container_node,
        ) orelse
            continue;

        try appendContainerDeclarationCandidates(
            allocator,
            tree,
            token_tags,
            references,
            container_decl.ast.members,
            candidates,
        );
    }
}

fn shouldDescendIntoDeclaration(
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: []const DeclReference,
    decl: Ast.Node.Index,
) bool {
    return unusedDeclarationProblem(
        tree,
        token_tags,
        references,
        decl,
    ) == null;
}

fn declarationContainerNode(tree: Ast, decl: Ast.Node.Index) ?Ast.Node.Index {
    const var_decl = tree.fullVarDecl(decl) orelse
        return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse
        return null;

    var buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&buffer, init_node) != null)
        return init_node;

    return null;
}

fn unusedDeclarationProblem(
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: []const DeclReference,
    decl: Ast.Node.Index,
) ?DeclarationProblem {
    const first_token = tree.firstToken(decl);
    const last_token = tree.lastToken(decl);

    if (tree.fullVarDecl(decl)) |var_decl| {
        if (isPublicVarDecl(tree, var_decl) or
            hasExternOrExport(token_tags, var_decl.extern_export_token))
            return null;

        const name_token = varDeclNameToken(var_decl);
        if (!hasExternalReference(
            references,
            tree.tokenSlice(name_token),
            first_token,
            last_token,
        ))
            return .{
                .first = first_token,
                .last = last_token + 1, // "+ 1" to consume the semicolon for this statement
            };
    } else {
        var buffer: [1]Ast.Node.Index = undefined;
        if (namedFnDeclProto(
            tree,
            &buffer,
            decl,
        )) |fn_proto| {
            if (isPublicFnProto(tree, fn_proto) or
                hasExternOrExport(token_tags, fn_proto.extern_export_inline_token))
                return null;

            const name_token = fnDeclNameToken(fn_proto) orelse return null;
            if (!hasExternalReference(
                references,
                tree.tokenSlice(name_token),
                first_token,
                last_token,
            ))
                return .{
                    .first = first_token,
                    .last = last_token,
                };
        }
    }
    return null;
}

fn hasExternalReference(
    references: []const DeclReference,
    name: []const u8,
    first_token: Ast.TokenIndex,
    last_token: Ast.TokenIndex,
) bool {
    for (references) |reference| {
        if (!std.mem.eql(u8, reference.name, name))
            continue;

        if (reference.token >= first_token and reference.token <= last_token)
            continue;

        return true;
    }
    return false;
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

fn varDeclNameToken(var_decl: Ast.full.VarDecl) Ast.TokenIndex {
    return var_decl.ast.mut_token + 1;
}

fn fnDeclNameToken(fn_proto: Ast.full.FnProto) ?Ast.TokenIndex {
    return fn_proto.name_token;
}

fn hasExternOrExport(
    token_tags: []const std.zig.Token.Tag,
    token: ?Ast.TokenIndex,
) bool {
    const t = token orelse return false;
    return token_tags[t] == .keyword_export or token_tags[t] == .keyword_extern;
}

fn isPublicVarDecl(tree: Ast, var_decl: Ast.full.VarDecl) bool {
    return zlinter.ast.varDeclVisibility(tree, var_decl) == .public;
}

fn isPublicFnProto(tree: Ast, fn_proto: Ast.full.FnProto) bool {
    return zlinter.ast.fnProtoVisibility(tree, fn_proto) == .public;
}

fn referencedDeclReference(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    rule_arena: std.mem.Allocator,
    node: Ast.Node.Index,
) ?DeclReference {
    const tree = doc.tree(session);
    std.debug.assert(tree.nodeTag(node) == .field_access);

    {
        const decl_candidates = session.resolveDeclCandidatesOfNode(rule_arena, doc, node) catch return null;
        if (referencedDeclNameFromCandidates(
            session,
            doc,
            decl_candidates.items,
        )) |name|
            return .{
                .name = name,
                .node = node,
                .token = tree.nodeMainToken(node),
            };
    }

    const lhs, const member_token = tree.nodeData(node).node_and_token;
    const member_name = tree.tokenSlice(member_token);

    if (isCallCallee(tree, doc, node)) {
        const root_decl_id = session.decl_store.rootDecl(doc.file_id) orelse return null;
        const member_candidates = session.resolveDeclMemberCandidates(
            rule_arena,
            root_decl_id,
            member_name,
        ) catch return null;
        if (referencedDeclNameFromCandidates(
            session,
            doc,
            member_candidates.items,
        )) |name|
            return .{
                .name = name,
                .node = node,
                .token = member_token,
            };
    }

    {
        const type_candidates = session.resolveTypeCandidatesOfNode(rule_arena, doc, lhs) catch return null;
        if (session.decl_store.rootDecl(doc.file_id)) |root_decl_id| {
            for (type_candidates.items) |candidate| {
                if (candidate.type.decl_id == root_decl_id)
                    return .{
                        .name = member_name,
                        .node = node,
                        .token = member_token,
                    };
            }
        }
    }
    return null;
}

fn referencedDeclNameFromCandidates(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    candidates: []const zlinter.session.LintSession.DeclCandidate,
) ?[]const u8 {
    const tree = doc.tree(session);
    for (candidates) |candidate| {
        if (session.decl_store.declFileId(candidate.decl_id) != doc.file_id)
            continue;

        const name_token = session.decl_store.declNameToken(candidate.decl_id) orelse
            continue;
        return tree.tokenSlice(name_token);
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

    // Rule-level regression: unsupported declarations in the same file should
    // not stop later same-file members from resolving as used.
    try zlinter.testing.testRunRule(
        rule,
        \\const Store = @This();
        \\
        \\extern fn () void;
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

    // A declaration's own body should not be enough to mark it used.
    try zlinter.testing.testRunRule(
        rule,
        \\fn recurse() void {
        \\    recurse();
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\fn recurse() void {
                \\    recurse();
                \\}
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 0,
                    .end = 36,
                    .text = "",
                },
            },
        },
    );

    // Ordinary references from another root declaration still count.
    try zlinter.testing.testRunRule(
        rule,
        \\fn helper() void {}
        \\
        \\pub fn main() void {
        \\    helper();
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    // Private declarations inside public containers are checked.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Parser = struct {
        \\    fn unusedHelper() void {}
        \\
        \\    pub fn parse() void {}
        \\};
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice = "fn unusedHelper() void {}",
                .message = "Unused declaration",
                .fix = .{
                    .start = 28,
                    .end = 58,
                    .text = "",
                },
            },
        },
    );

    // References from another declaration in the same container count.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Parser = struct {
        \\    fn helper() void {}
        \\
        \\    pub fn parse() void {
        \\        helper();
        \\    }
        \\};
    ,
        .{},
        Config{},
        &.{},
    );

    // An unused private root container is still reported only at the root.
    try zlinter.testing.testRunRule(
        rule,
        \\const Parser = struct {
        \\    fn unusedHelper() void {}
        \\
        \\    pub fn parse() void {}
        \\};
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\const Parser = struct {
                \\    fn unusedHelper() void {}
                \\
                \\    pub fn parse() void {}
                \\};
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 0,
                    .end = 84,
                    .text = "",
                },
            },
        },
    );

    // Public nested declarations are skipped like public root declarations.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Parser = struct {
        \\    pub fn helper() void {}
        \\
        \\    pub const Nested = struct {};
        \\};
    ,
        .{},
        Config{},
        &.{},
    );

    // Function-local declarations are not treated as container declarations.
    try zlinter.testing.testRunRule(
        rule,
        \\pub fn main() void {
        \\    const Local = struct {
        \\        fn unusedHelper() void {}
        \\    };
        \\    _ = Local;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    // Self references in a malformed initializer should not crash or mark the
    // declaration used.
    try zlinter.testing.testRunRule(
        rule,
        \\const bad = bad
    ,
        .{ .allow_parse_errors = true },
        Config{},
        &.{},
    );
}

test "no_unused - extern declarations" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    try zlinter.testing.testRunRule(
        rule,
        \\extern fn puts([*:0]const u8) c_int;
        \\extern var errno: c_int;
        \\export fn exported_fn() void {}
        \\export const exported_var = 1;
        \\
        \\fn unused_private() void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\fn unused_private() void {}
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 126,
                    .end = 153,
                    .text = "",
                },
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
