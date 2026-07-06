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
    const zone = zlinter.tracy.traceNamed(@src(), "rule.no_unused");
    defer zone.end();
    zone.addText(doc.absPath(session));

    const config = options.getConfig(Config);
    if (config.container_declaration == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);
    const token_tags = tree.tokens.items(.tag);

    var container_references = ReferenceIndex{};
    var unused_problem_by_decl: std.AutoHashMapUnmanaged(
        Ast.Node.Index,
        ?DeclarationProblem,
    ) = .empty;

    // Store referenced identifiers and field accesses by name. This lets
    // declaration checks ignore self-references without rescanning every
    // reference in the file for each declaration.
    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        switch (tree.nodeTag(node)) {
            .identifier => try container_references.append(
                rule_arena,
                .{
                    .name = tree.tokenSlice(tree.nodeMainToken(node)),
                    .token = tree.nodeMainToken(node),
                },
            ),
            .field_access => {
                const member_token = tree.nodeData(node).node_and_token[1];
                try container_references.append(
                    rule_arena,
                    .{
                        .name = tree.tokenSlice(member_token),
                        .token = member_token,
                    },
                );
            },
            .enum_literal => try container_references.append(
                rule_arena,
                .{
                    .name = tree.tokenSlice(tree.nodeMainToken(node)),
                    .token = tree.nodeMainToken(node),
                },
            ),
            else => {},
        }
    }

    const candidate_decls = try containerDeclarationCandidates(
        rule_arena,
        tree,
        token_tags,
        &container_references,
        &unused_problem_by_decl,
    );

    for (candidate_decls.items) |decl| {
        const problem = try cachedUnusedDeclarationProblem(
            rule_arena,
            tree,
            token_tags,
            &container_references,
            decl,
            &unused_problem_by_decl,
        );

        if (problem) |p| {
            const first_token = p.first;
            const last_token = p.last;
            const removal_range = declarationRemovalRange(
                tree,
                decl,
                last_token,
            );

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.container_declaration,
                .start = .startOfToken(tree, first_token),
                .end = .endOfToken(tree, last_token),
                .message = try session_arena.dupe(u8, "Unused declaration"),
                .fix = .{
                    .start = removal_range.start,
                    .end = removal_range.end,
                    .text = "",
                },
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

const DeclReference = struct {
    name: []const u8,
    token: Ast.TokenIndex,
};

const ReferenceIndex = struct {
    by_name: std.StringHashMapUnmanaged(std.ArrayList(DeclReference)) = .empty,

    fn append(
        self: *ReferenceIndex,
        allocator: std.mem.Allocator,
        reference: DeclReference,
    ) !void {
        const entry = try self.by_name.getOrPut(allocator, reference.name);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(allocator, reference);
    }

    fn referencesForName(
        self: *const ReferenceIndex,
        name: []const u8,
    ) []const DeclReference {
        const refs = self.by_name.get(name) orelse return &.{};
        return refs.items;
    }
};

const DeclarationProblem = struct {
    first: Ast.TokenIndex,
    last: Ast.TokenIndex,
};

const RemovalRange = struct {
    start: usize,
    end: usize,
};

fn declarationRemovalRange(
    tree: Ast,
    decl: Ast.Node.Index,
    last_token: Ast.TokenIndex,
) RemovalRange {
    const first_token = firstTokenIncludingAttachedDocComments(
        tree,
        tree.firstToken(decl),
    );

    const start = tree.tokenLocation(0, first_token);
    const end = tree.tokenLocation(0, last_token);

    const start_newline: bool = if (first_token > 0)
        tree.tokenLocation(0, first_token - 1).line < start.line
    else
        true;

    const end_newline: bool = if (last_token + 1 < tree.tokens.len)
        tree.tokenLocation(0, last_token + 1).line > end.line
    else
        true;

    const end_offset: usize = if (start_newline and end_newline) 1 else 0;

    return .{
        .start = start.line_start,
        .end = end.line_end + end_offset,
    };
}

fn firstTokenIncludingAttachedDocComments(
    tree: Ast,
    first_token: Ast.TokenIndex,
) Ast.TokenIndex {
    var token = first_token;

    while (token > 0 and
        tree.tokenTag(token - 1) == .doc_comment and
        tokensAreAttachedWithoutBlankLine(
            tree,
            token - 1,
            token,
        ))
        token -= 1;

    return token;
}

fn tokensAreAttachedWithoutBlankLine(
    tree: Ast,
    first_token: Ast.TokenIndex,
    second_token: Ast.TokenIndex,
) bool {
    const first_end = tree.tokenStart(first_token) +
        tree.tokenSlice(first_token).len;
    const second_start = tree.tokenStart(second_token);

    if (first_end >= second_start) return true;

    return !containsBlankLine(tree.source[first_end..second_start]);
}

fn containsBlankLine(bytes: []const u8) bool {
    var line_has_non_whitespace = false;
    var saw_newline = false;

    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        switch (bytes[i]) {
            '\n' => {
                if (saw_newline and !line_has_non_whitespace) return true;
                saw_newline = true;
                line_has_non_whitespace = false;
            },
            '\r', ' ', '\t' => {},
            else => line_has_non_whitespace = true,
        }
    }

    return false;
}

fn containerDeclarationCandidates(
    allocator: std.mem.Allocator,
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: *const ReferenceIndex,
    unused_problem_by_decl: *std.AutoHashMapUnmanaged(
        Ast.Node.Index,
        ?DeclarationProblem,
    ),
) !std.ArrayList(Ast.Node.Index) {
    var candidates = std.ArrayList(Ast.Node.Index).empty;
    try appendContainerDeclarationCandidates(
        allocator,
        tree,
        token_tags,
        references,
        unused_problem_by_decl,
        tree.rootDecls(),
        &candidates,
    );
    return candidates;
}

fn appendContainerDeclarationCandidates(
    allocator: std.mem.Allocator,
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: *const ReferenceIndex,
    unused_problem_by_decl: *std.AutoHashMapUnmanaged(
        Ast.Node.Index,
        ?DeclarationProblem,
    ),
    members: []const Ast.Node.Index,
    candidates: *std.ArrayList(Ast.Node.Index),
) !void {
    for (members) |member| {
        try candidates.append(allocator, member);

        if ((try cachedUnusedDeclarationProblem(
            allocator,
            tree,
            token_tags,
            references,
            member,
            unused_problem_by_decl,
        )) != null)
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
            unused_problem_by_decl,
            container_decl.ast.members,
            candidates,
        );
    }
}

fn cachedUnusedDeclarationProblem(
    allocator: std.mem.Allocator,
    tree: Ast,
    token_tags: []const std.zig.Token.Tag,
    references: *const ReferenceIndex,
    decl: Ast.Node.Index,
    unused_problem_by_decl: *std.AutoHashMapUnmanaged(
        Ast.Node.Index,
        ?DeclarationProblem,
    ),
) !?DeclarationProblem {
    const entry = try unused_problem_by_decl.getOrPut(
        allocator,
        decl,
    );
    if (!entry.found_existing) {
        entry.value_ptr.* = unusedDeclarationProblem(
            tree,
            token_tags,
            references,
            decl,
        );
    }
    return entry.value_ptr.*;
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
    references: *const ReferenceIndex,
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
    references: *const ReferenceIndex,
    name: []const u8,
    first_token: Ast.TokenIndex,
    last_token: Ast.TokenIndex,
) bool {
    for (references.referencesForName(name)) |reference| {
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

    inline for (&.{ .warning, .@"error" }) |severity|
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

    // Inferred field syntax should count as used too.
    try zlinter.testing.testRunRule(
        rule,
        \\const Printer = struct {
        \\    const empty: Printer = .{};
        \\};
        \\
        \\const printer_singleton: Printer = .empty;
        \\
        \\pub fn main() void {
        \\    _ = printer_singleton;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    // Inferred method syntax should not be reported as unused.
    try zlinter.testing.testRunRule(
        rule,
        \\const ChildIterator = struct {
        \\    fn initArray() ChildIterator {
        \\        return .{};
        \\    }
        \\
        \\    fn used() ChildIterator {
        \\        return .initArray();
        \\    }
        \\};
        \\
        \\pub fn main() void {
        \\    _ = ChildIterator.used();
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

    // Nested enum methods called through values should count as used.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Token = struct {
        \\    tag: Tag,
        \\
        \\    const Tag = enum {
        \\        doc_comment,
        \\
        \\        fn isComment(self: Tag) bool {
        \\            _ = self;
        \\            return true;
        \\        }
        \\    };
        \\
        \\    pub fn main(token: Token) void {
        \\        _ = token.tag.isComment();
        \\    }
        \\};
    ,
        .{},
        Config{},
        &.{},
    );

    // Nested struct methods called through values should count as used too.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Comments = struct {
        \\    const Comment = struct {
        \\        value: u32,
        \\
        \\        fn debugPrint(self: Comment) void {
        \\            _ = self.value;
        \\        }
        \\    };
        \\
        \\    pub fn main(comment: Comment) void {
        \\        comment.debugPrint();
        \\    }
        \\};
    ,
        .{},
        Config{},
        &.{},
    );

    // Chained access through indexing should still mark nested enum methods as used.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Parser = struct {
        \\    tokens: []const Token,
        \\    i: usize,
        \\
        \\    const Token = struct {
        \\        tag: Tag,
        \\
        \\        const Tag = enum {
        \\            doc_comment,
        \\
        \\            fn isComment(self: Tag) bool {
        \\                _ = self;
        \\                return true;
        \\            }
        \\        };
        \\    };
        \\
        \\    pub fn main(p: Parser) void {
        \\        if (!p.tokens[p.i].tag.isComment()) return;
        \\    }
        \\};
    ,
        .{},
        Config{},
        &.{},
    );

    // Methods on loop elements should count as used too.
    try zlinter.testing.testRunRule(
        rule,
        \\pub const Comments = struct {
        \\    const Comment = struct {
        \\        value: u32,
        \\
        \\        fn debugPrint(self: Comment) void {
        \\            _ = self.value;
        \\        }
        \\    };
        \\
        \\    pub fn main(items: []const Comment) void {
        \\        for (items) |comment| comment.debugPrint();
        \\    }
        \\};
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

test "no_unused - fix removes attached doc comments" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    try zlinter.testing.testRunRule(
        rule,
        \\/// Internal helper used by old parser.
        \\fn oldParser() void {}
        \\
        \\pub fn main() void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\fn oldParser() void {}
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 0,
                    .end = 63,
                    .text = "",
                },
            },
        },
    );
}

test "no_unused - fix preserves separated section comments" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    try zlinter.testing.testRunRule(
        rule,
        \\// Parser helpers
        \\
        \\fn oldParser() void {}
        \\
        \\pub fn main() void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\fn oldParser() void {}
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 19,
                    .end = 42,
                    .text = "",
                },
            },
        },
    );
}

test "no_unused - fix preserves comments for adjacent used declarations" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    try zlinter.testing.testRunRule(
        rule,
        \\/// Remove me.
        \\fn oldParser() void {}
        \\
        \\/// Keep me.
        \\fn helper() void {}
        \\
        \\pub fn main() void {
        \\    helper();
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\fn oldParser() void {}
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 0,
                    .end = 38,
                    .text = "",
                },
            },
        },
    );
}

test "no_unused - fix removes attached doc comments for multi-line declarations" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    try zlinter.testing.testRunRule(
        rule,
        \\/// Remove parser.
        \\fn oldParser(
        \\    input: []const u8,
        \\) void {
        \\    _ = input;
        \\}
        \\
        \\pub fn main() void {}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "no_unused",
                .severity = .warning,
                .slice =
                \\fn oldParser(
                \\    input: []const u8,
                \\) void {
                \\    _ = input;
                \\}
                ,
                .message = "Unused declaration",
                .fix = .{
                    .start = 0,
                    .end = 82,
                    .text = "",
                },
            },
        },
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
