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
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_doc_comment),
        .run = &run,
    };
}

/// Runs the require_doc_comment rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);
    const root: Ast.Node.Index = .root;

    if (config.file_severity != .off) {
        if (!hasDocComments(tree, root)) {
            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.file_severity,
                .start = .startOfNode(tree, root),
                .end = .startOfNode(tree, root),
                .message = try session_arena.dupe(u8, "File is missing a doc comment"),
            });
        }
    }

    const should_check_decls = config.private_severity != .off or config.public_severity != .off;
    if (should_check_decls) {
        var it = try doc.nodeLineageIterator(root, rule_arena);

        var fn_decl_buffer: [1]Ast.Node.Index = undefined;

        nodes: while (try it.next()) |tuple| {
            const node, const connections = tuple;

            if (!zlinter.ast.isContainerMember(tree, connections)) continue :nodes;

            if (tree.fullFnProto(&fn_decl_buffer, node)) |fn_decl| {
                const severity, const label = switch (zlinter.ast.fnProtoVisibility(tree, fn_decl)) {
                    .private => .{ config.private_severity, "Private" },
                    .public => .{ config.public_severity, "Public" },
                };
                if (severity == .off) continue :nodes;

                if (hasDocComments(tree, node))
                    continue :nodes;

                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(node)),
                    .end = .endOfNode(tree, fn_decl.ast.proto_node),
                    .message = try std.fmt.allocPrint(session_arena, "{s} function is missing a doc comment", .{label}),
                });
                continue :nodes;
            }

            if (tree.fullVarDecl(node)) |var_decl| {
                const severity, const label = switch (zlinter.ast.varDeclVisibility(tree, var_decl)) {
                    .private => .{ config.private_severity, "Private" },
                    .public => .{ config.public_severity, "Public" },
                };
                if (severity == .off) continue :nodes;

                if (hasDocComments(tree, node)) continue :nodes;

                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(node)),
                    .end = .endOfToken(tree, var_decl.ast.mut_token + 1),
                    .message = try std.fmt.allocPrint(session_arena, "{s} declaration is missing a doc comment", .{label}),
                });
            }
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

fn hasDocComments(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .root => tree.tokenTag(0) == .container_doc_comment,
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .fn_decl,
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        => hasAttachedDocComment(tree, node),
        else => false,
    };
}

fn hasAttachedDocComment(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .global_var_decl,
        .local_var_decl,
        .aligned_var_decl,
        .simple_var_decl,
        .fn_decl,
        .fn_proto,
        .fn_proto_multi,
        .fn_proto_one,
        .fn_proto_simple,
        => has_doc_comments: {
            const first = tree.firstToken(node);
            if (first == 0) break :has_doc_comments false;
            if (tree.tokenTag(first - 1) != .doc_comment) break :has_doc_comments false;

            const prev_end = tree.tokenStart(first - 1) + tree.tokenSlice(first - 1).len;
            const first_start = tree.tokenStart(first);
            if (prev_end >= first_start) break :has_doc_comments true;

            break :has_doc_comments !containsBlankLine(tree.source[prev_end..first_start]);
        },
        else => false,
    };
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
            '\r' => {
                if (saw_newline and !line_has_non_whitespace) return true;
                saw_newline = true;
                line_has_non_whitespace = false;
                if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
            },
            ' ', '\t' => {},
            else => line_has_non_whitespace = true,
        }
    }

    return false;
}

test "require_doc_comment - public" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\pub fn noDoc() void {
        \\}
        \\
        \\pub extern fn missingExternDoc(size: usize) void;
        \\
        \\/// Doc comment
        \\pub fn hasDocComment() void {
        \\}
        \\
        \\/// Doc comment
        \\pub extern fn hasExternDoc(size: usize) void;
        \\
        \\pub const name = "jack";
        \\
        \\/// Doc comment
        \\pub const name_with_comment = "jack";
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .public_severity = severity },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "pub const name",
                    .message = "Public declaration is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "pub extern fn missingExternDoc(size: usize) void",
                    .message = "Public function is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "pub fn noDoc() void",
                    .message = "Public function is missing a doc comment",
                },
            },
        );
    }

    // off
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .public_severity = .off },
        &.{},
    );
}

test "require_doc_comment - private" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\fn noDoc() void {
        \\    const local_const = 1;
        \\    var local_var: usize = 0;
        \\    _ = local_const;
        \\    _ = local_var;
        \\}
        \\
        \\extern fn missingExternDoc(size: usize) void;
        \\
        \\/// Doc comment
        \\fn hasDocComment() void {
        \\}
        \\
        \\/// Doc comment
        \\extern fn hasExternDoc(size: usize) void;
        \\
        \\const name = "jack";
        \\
        \\/// Doc comment
        \\const name_with_comment = "jack";
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .private_severity = severity },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "const name",
                    .message = "Private declaration is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "extern fn missingExternDoc(size: usize) void",
                    .message = "Private function is missing a doc comment",
                },
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "fn noDoc() void",
                    .message = "Private function is missing a doc comment",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .private_severity = .off },
        &.{},
    );
}

test "require_doc_comment - file" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .file_severity = severity },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "",
                    .message = "File is missing a doc comment",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .file_severity = .off },
        &.{},
    );
}

test "require_doc_comment - file only" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .file_severity = severity,
                .public_severity = .off,
                .private_severity = .off,
            },
            &.{
                .{
                    .rule_id = "require_doc_comment",
                    .severity = severity,
                    .slice = "",
                    .message = "File is missing a doc comment",
                },
            },
        );
    }
}

test "hasDocComments - function prototype without params" {
    try expectPrototypeHasDocComment(
        \\/// Doc comment
        \\extern fn simple() void;
    );
}

test "hasDocComments - function prototype with one param" {
    try expectPrototypeHasDocComment(
        \\/// Doc comment
        \\pub fn one(arg: u8) void;
    );
}

test "hasDocComments - function prototype with many params" {
    try expectPrototypeHasDocComment(
        \\/// Doc comment
        \\pub fn multi(first: u8, second: u8) void;
    );
}

test "hasDocComments - unsupported nodes return false" {
    const source: [:0]const u8 =
        \\test "does not matter" {
        \\    const value = 1;
        \\    _ = value;
        \\}
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const test_decl = try zlinter.testing.expectSingleNodeOfTag(tree, &.{.test_decl});
    try std.testing.expect(!hasDocComments(tree, test_decl));
}

test "hasAttachedDocComment - attached single-line comment" {
    const source: [:0]const u8 =
        \\/// Attached.
        \\pub fn hasDoc() void;
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const node = try zlinter.testing.expectSingleNodeOfTag(
        tree,
        &.{ .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple },
    );
    try std.testing.expect(hasAttachedDocComment(tree, node));
}

test "hasAttachedDocComment - attached multi-line comment" {
    const source: [:0]const u8 =
        \\/// Line 1
        \\/// Line 2
        \\pub fn hasMultiDoc() void;
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const node = try zlinter.testing.expectSingleNodeOfTag(
        tree,
        &.{ .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple },
    );
    try std.testing.expect(hasAttachedDocComment(tree, node));
}

test "hasAttachedDocComment - detached comment" {
    const source: [:0]const u8 =
        \\/// Detached doc comment.
        \\
        \\pub fn missingDoc() void;
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const node = try zlinter.testing.expectSingleNodeOfTag(
        tree,
        &.{ .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple },
    );
    try std.testing.expect(!hasAttachedDocComment(tree, node));
}

test "hasAttachedDocComment - crlf line endings" {
    const raw = "/// Attached.\r\npub fn hasDoc() void;\r\n";
    const source = try std.testing.allocator.alloc(u8, raw.len + 1);
    defer std.testing.allocator.free(source);
    @memcpy(source[0..raw.len], raw);
    source[raw.len] = 0;
    const source_z: [:0]const u8 = source[0..raw.len :0];

    var tree = try Ast.parse(std.testing.allocator, source_z, .zig);
    defer tree.deinit(std.testing.allocator);

    const node = try zlinter.testing.expectSingleNodeOfTag(
        tree,
        &.{ .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple },
    );
    try std.testing.expect(hasAttachedDocComment(tree, node));
}

test "require_doc_comment - detached doc comment still reports" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\/// Detached doc comment.
        \\
        \\pub fn missingDoc() void;
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .public_severity = .warning },
        &.{
            .{
                .rule_id = "require_doc_comment",
                .severity = .warning,
                .slice = "pub fn missingDoc() void",
                .message = "Public function is missing a doc comment",
            },
        },
    );
}

test "require_doc_comment - attached doc comment suppresses report" {
    const rule = buildRule(.{});
    const source: [:0]const u8 =
        \\/// Attached.
        \\pub fn hasDoc() void;
    ;

    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .public_severity = .warning },
        &.{},
    );
}

fn expectPrototypeHasDocComment(source: [:0]const u8) !void {
    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const node = try zlinter.testing.expectSingleNodeOfTag(
        tree,
        &.{ .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple },
    );
    try std.testing.expect(hasDocComments(tree, node));
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;

test {
    std.testing.refAllDecls(@This());
}
