//! Enforces a consistent ordering of `@import` declarations by their local
//! declaration name in Zig source files.
//!
//! For example: `a` < `b` and not `apple` < `zebra`.
//!
//! ```
//! const a = @import("zebra");
//! const b = @import("apple");
//! ```
//!
//! Maintaining a standardized import order improves readability and reduces
//! merge conflicts.
//!
//! `import_ordering` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places. Fixes may be omitted when comments are attached to imports.
//!
//! ### Import chunks
//!
//! An import chunk is a consecutive group of import declarations in the same
//! scope.
//!
//! When `allow_line_separated_chunks` is `true`, imports separated by one or
//! more blank lines are treated as separate chunks, and each chunk is checked
//! independently.
//!
//! Comments do not split chunks. A `//` comment directly attached to an import
//! is treated as part of that import's chunk. A `//!` doc comment is not treated
//! as an attachable import comment.
//!
//! **Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**

/// Config for import_ordering rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// The order that the imports appear in, compared by the local declaration
    /// name.
    order: zlinter.rules.LintTextOrder = .alphabetical_ascending,

    /// Whether imports separated by blank lines are treated as independent
    /// chunks.
    /// When false, all imports in the same scope must form one contiguous
    /// chunk.
    allow_line_separated_chunks: bool = true,

    // TODO(#52): Decide whether or not to implement this:
    // /// Whether imports should be at the bottom or top of their parent scope.
    // location: enum { top, bottom, off } = .off,

    // TODO(#52): Decide whether of not to implement this
    // /// Whether or not to group the imports by their visibility or source.
    // group: struct {
    //     /// public and private separately.
    //     visibilty: bool = false,
    //     /// enternal and local separately.
    //     source: bool = false,
    // } = .{},
};

/// Builds and returns the import_ordering rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.import_ordering),
        .execution = .syntax_only,
        .run = &run,
    };
}

/// Runs the import_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
    defer lint_problems.deinit(gpa);

    var scoped_imports = try resolveScopedImports(doc, session, gpa);
    defer deinitScopedImports(gpa, &scoped_imports);

    const tree = doc.tree(session);
    var import_it = scoped_imports.iterator();
    scopes: while (import_it.next()) |e| {
        var imports = e.value_ptr;
        var previous: ?ImportDecl = null;

        while (imports.popMin()) |import| {
            if (previous) |p| {
                const is_same_chunk = (p.last_line + 1) >= import.first_line;
                const same_line = p.first_line == import.first_line;

                if (!config.allow_line_separated_chunks and !is_same_chunk) {
                    try lint_problems.append(gpa, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, import.decl_node),
                        .end = .endOfNode(tree, import.decl_node),
                        .message = try std.fmt.allocPrint(gpa, "Import '{s}' should be grouped with other imports", .{import.decl_name}),
                        .fix = if (same_line) null else try swapImportBlocksFix(doc, session, p.decl_node, import.decl_node, gpa),
                    });
                    continue :scopes;
                }

                if (is_same_chunk) {
                    // Import ordering is intentionally based on the local declaration
                    // name, not the import path.
                    const order = config.order.cmp(import.decl_name, p.decl_name);
                    if (order == .lt) {
                        try lint_problems.append(gpa, .{
                            .rule_id = rule.rule_id,
                            .severity = config.severity,
                            .start = .startOfNode(tree, import.decl_node),
                            .end = .endOfNode(tree, import.decl_node),
                            .message = try std.fmt.allocPrint(gpa, "Import '{s}' is not in {s} order", .{ import.decl_name, config.order.name() }),
                            .fix = if (same_line) null else try swapImportBlocksFix(doc, session, p.decl_node, import.decl_node, gpa),
                        });
                        continue :scopes;
                    }
                }
            }
            previous = import;
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.absPath(session),
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

// TODO(#52): Write unit tests for helpers and consider whether some should be moved to ast

const ImportsQueueLinesAscending = std.PriorityDequeue(
    ImportDecl,
    void,
    ImportDecl.compareSourceAscending,
);

const ImportDecl = struct {
    decl_node: Ast.Node.Index,
    /// Local declaration name used to order imports.
    decl_name: []const u8,
    classification: Classification,
    first_line: usize,
    last_line: usize,
    start_offset: usize,
    end_offset: usize,

    const Classification = enum { local, external };

    pub fn compareSourceAscending(_: void, a: ImportDecl, b: ImportDecl) std.math.Order {
        const line_order = std.math.order(a.first_line, b.first_line);
        if (line_order != .eq) return line_order;

        return std.math.order(a.start_offset, b.start_offset);
    }
};

fn deinitScopedImports(gpa: std.mem.Allocator, scoped_imports: *std.array_hash_map.Auto(Ast.Node.Index, ImportsQueueLinesAscending)) void {
    for (scoped_imports.values()) |*v| v.deinit(gpa);
    scoped_imports.deinit(gpa);
}

const ImportSwapRange = struct {
    start_line: usize,
    end_line: usize,
    start_offset: usize,
    end_offset: usize,
};

fn swapImportBlocksFix(
    doc: *const zlinter.session.LintDocument,
    session: *const zlinter.session.LintSession,
    first: Ast.Node.Index,
    second: Ast.Node.Index,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!?zlinter.results.LintProblemFix {
    const tree = doc.tree(session);
    const source = tree.source;

    const first_range = importSwapRange(
        doc,
        session,
        first,
    ) orelse return null;
    const second_range = importSwapRange(
        doc,
        session,
        second,
    ) orelse return null;

    if (first_range.start_offset >= second_range.start_offset) return null;
    if (!sourceRangeIsBlankOnly(
        doc.comments.line_starts,
        source,
        first_range.end_line + 1,
        second_range.start_line,
    ))
        return null;

    var text = try std.ArrayList(u8).initCapacity(
        gpa,
        second_range.end_offset + 1 - first_range.start_offset,
    );
    errdefer text.deinit(gpa);

    try text.appendSlice(
        gpa,
        source[second_range.start_offset..second_range.end_offset],
    );
    try text.appendSlice(
        gpa,
        source[first_range.end_offset..second_range.start_offset],
    );
    try text.appendSlice(
        gpa,
        source[first_range.start_offset..first_range.end_offset],
    );

    return .{
        .text = try text.toOwnedSlice(gpa),
        .start = first_range.start_offset,
        .end = second_range.end_offset,
    };
}

fn importSwapRange(
    doc: *const zlinter.session.LintDocument,
    session: *const zlinter.session.LintSession,
    node: Ast.Node.Index,
) ?ImportSwapRange {
    const tree = doc.tree(session);
    const source = tree.source;
    const line_starts = doc.comments.line_starts;

    const first_token = tree.firstToken(node);
    const last_token = tree.lastToken(node);
    const start_line = tree.tokenLocation(0, first_token).line;
    const end_line = tree.tokenLocation(0, last_token).line;

    var block_start_line = start_line;
    while (block_start_line > 0) {
        const prev_line = block_start_line - 1;
        const line = lineSlice(
            source,
            line_starts,
            prev_line,
        );

        if (isBlankLine(line)) break;
        if (!isAttachableImportCommentLine(line)) break;

        block_start_line = prev_line;
    }

    return .{
        .start_line = block_start_line,
        .end_line = end_line,
        .start_offset = line_starts[block_start_line],
        .end_offset = lineEndExclusive(
            source,
            line_starts,
            end_line,
        ),
    };
}

fn sourceRangeIsBlankOnly(
    line_starts: []const usize,
    source: [:0]const u8,
    start_line: usize,
    end_line: usize,
) bool {
    if (start_line >= end_line) return true;
    var line = start_line;
    while (line < end_line) : (line += 1) {
        if (!isBlankLine(lineSlice(
            source,
            line_starts,
            line,
        ))) return false;
    }
    return true;
}

fn lineSlice(
    source: [:0]const u8,
    line_starts: []const usize,
    line: usize,
) []const u8 {
    const start = line_starts[line];
    const end = lineEndExclusive(
        source,
        line_starts,
        line,
    );
    return source[start..end];
}

fn lineEndExclusive(
    source: [:0]const u8,
    line_starts: []const usize,
    line: usize,
) usize {
    return if (line + 1 < line_starts.len) line_starts[line + 1] else source.len;
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => {},
            else => return false,
        }
    }
    return true;
}

fn isAttachableImportCommentLine(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        switch (line[i]) {
            ' ', '\t', '\r' => continue,
            else => break,
        }
    }
    const trimmed = line[i..];
    return std.mem.startsWith(u8, trimmed, "//") and
        !std.mem.startsWith(u8, trimmed, "//!");
}

/// Returns declarations initialised as imports grouped by their parent (i.e., their scope).
fn resolveScopedImports(
    doc: *const zlinter.session.LintDocument,
    session: *const zlinter.session.LintSession,
    gpa: std.mem.Allocator,
) !std.array_hash_map.Auto(Ast.Node.Index, ImportsQueueLinesAscending) {
    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var node_it = try doc.nodeLineageIterator(root, gpa);
    defer node_it.deinit();

    var scoped_imports: std.array_hash_map.Auto(Ast.Node.Index, ImportsQueueLinesAscending) = .empty;
    while (try node_it.next()) |tuple| {
        const node, const connections = tuple;

        const var_decl = tree.fullVarDecl(node) orelse continue;

        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        const import_path = isImportCall(tree, init_node) orelse continue;
        const parent = connections.parent orelse continue;

        const decl_name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const classification = classifyImportKind(.init(import_path));

        const first_loc = tree.tokenLocation(0, tree.firstToken(node));
        const last_loc = tree.tokenLocation(0, tree.lastToken(node));

        const import = ImportDecl{
            .decl_node = node,
            .decl_name = decl_name,
            .classification = classification,
            .first_line = first_loc.line,
            .last_line = last_loc.line,
            .start_offset = tree.tokenStart(tree.firstToken(node)),
            .end_offset = tree.tokenStart(tree.lastToken(node)) + tree.tokenSlice(tree.lastToken(node)).len,
        };

        var gop = try scoped_imports.getOrPut(gpa, parent);
        if (gop.found_existing) {
            try gop.value_ptr.push(gpa, import);
        } else {
            var imports: ImportsQueueLinesAscending = .empty;
            errdefer imports.deinit(gpa);

            try imports.push(gpa, import);
            gop.value_ptr.* = imports;
        }
    }
    return scoped_imports;
}

/// Returns the import path if `@import` built in call.
fn isImportCall(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const main_token = tree.nodeMainToken(node);
            if (!std.mem.eql(u8, "@import", tree.tokenSlice(main_token))) return null;

            const data = tree.nodeData(node);
            const lhs_node = data.opt_node_and_opt_node[0].unwrap() orelse return null;

            if (tree.nodeTag(lhs_node) != .string_literal) return null;

            const lhs_content = tree.tokenSlice(tree.nodeMainToken(lhs_node));
            if (lhs_content.len <= 2) return null;

            return lhs_content[1 .. lhs_content.len - 1];
        },
        else => return null,
    }
}

fn classifyImportKind(kind: import_utils.Kind) ImportDecl.Classification {
    return switch (kind) {
        .relative => .local,
        .stdlib,
        .root,
        .builtin,
        .module,
        => .external,
    };
}

// TODO(#52): Move to ast module
// zlinter-disable-next-line
// fn getScopedNode(doc: *const zlinter.session.LintDocument, node: Ast.Node.Index) Ast.Node.Index {
//     var parent = doc.lineage.items(.parent)[node];
//     while (parent) |parent_node| {
//         switch (doc.handle.tree.nodeTag(parent_node)) {
//             .block_two,
//             .block_two_semicolon,
//             .block,
//             .block_semicolon,
//             .container_decl,
//             .container_decl_trailing,
//             .container_decl_two,
//             .container_decl_two_trailing,
//             .container_decl_arg,
//             .container_decl_arg_trailing,
//             => return parent_node,
//             else => parent = doc.lineage.items(.parent)[parent_node],
//         }
//     }
//     return .root;
// }

test {
    std.testing.refAllDecls(@This());
}

test "order" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\ const b = @import("b");
        \\ const c = @import("c");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\ const b = @import("b");
        \\ const c = @import("c");
    ,
        .{},
        Config{
            .order = .alphabetical_descending,
            .allow_line_separated_chunks = false,
        },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const b = @import("b")
                ,
                .message = "Import 'b' is not in reverse alphabetical order",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 0,
                    .end = 50,
                    .text =
                    \\ const b = @import("b");
                    \\ const a = @import("a");
                    \\
                    ,
                },
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\ const c = @import("c");
        \\ const b = @import("b");
    ,
        .{},
        Config{ .order = .alphabetical_ascending, .severity = .@"error" },
        &.{.{
            .rule_id = "import_ordering",
            .severity = .@"error",
            .slice =
            \\const b = @import("b")
            ,
            .message = "Import 'b' is not in alphabetical order",
            .disabled_by_comment = false,
            .fix = .{
                .start = 25,
                .end = 75,
                .text =
                \\ const b = @import("b");
                \\ const c = @import("c");
                ,
            },
        }},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\ const c = @import("c");
        \\
        \\ const b = @import("b");
        \\ const d = @import("d");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\ const b = @import("b");
        \\
        \\ const d = @import("d");
        \\ const c = @import("c");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const c = @import("c")
                ,
                .message = "Import 'c' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 51,
                    .end = 101,
                    .text =
                    \\ const c = @import("c");
                    \\ const d = @import("d");
                    ,
                },
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import(
        \\   "b",
        \\ );
        \\ const a = @import("a");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("a")
                ,
                .message = "Import 'a' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 0,
                    .end = 57,
                    .text =
                    \\ const a = @import("a");
                    \\ const b = @import(
                    \\   "b",
                    \\ );
                    ,
                },
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import("b");
        \\ const a = @import("a");
        \\
        \\ const namespace = struct {
        \\   const b_inner = @import("b");
        \\   const a_inner = @import("a");
        \\ };
        \\
        \\ fn main() void {
        \\   const b_main = @import("b");
        \\   const a_main = @import("a");
        \\ }
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a_main = @import("a")
                ,
                .message = "Import 'a_main' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 168,
                    .end = 232,
                    .text =
                    \\   const a_main = @import("a");
                    \\   const b_main = @import("b");
                    \\
                    ,
                },
            },
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a_inner = @import("a")
                ,
                .message = "Import 'a_inner' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 79,
                    .end = 145,
                    .text =
                    \\   const a_inner = @import("a");
                    \\   const b_inner = @import("b");
                    \\
                    ,
                },
            },
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("a")
                ,
                .message = "Import 'a' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = .{
                    .start = 0,
                    .end = 50,
                    .text =
                    \\ const a = @import("a");
                    \\ const b = @import("b");
                    \\
                    ,
                },
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a"); const b = @import("b");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import("b"); const a = @import("a");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("a")
                ,
                .message = "Import 'a' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = null,
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("z"); const b = @import("a");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import("a"); const a = @import("z");
    ,
        .{},
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("z")
                ,
                .message = "Import 'a' is not in alphabetical order",
                .disabled_by_comment = false,
                .fix = null,
            },
        },
    );
}

test "allow_line_separated_chunks" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "",
        .{},
        Config{ .allow_line_separated_chunks = true },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
    ,
        .{},
        Config{ .allow_line_separated_chunks = true },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import("b");
        \\
        \\ const a = @import("a");
    ,
        .{},
        Config{ .allow_line_separated_chunks = true },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import(
        \\   "b",
        \\ );
        \\
        \\ const a = @import("a");
    ,
        .{},
        Config{ .allow_line_separated_chunks = true },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import(
        \\   "b",
        \\ );
        \\
        \\ const a = @import("a");
    ,
        .{},
        Config{ .allow_line_separated_chunks = false },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("a")
                ,
                .message = "Import 'a' should be grouped with other imports",
                .fix = .{
                    .start = 0,
                    .end = 58,
                    .text =
                    \\ const a = @import("a");
                    \\ const b = @import(
                    \\   "b",
                    \\ );
                    \\
                    ,
                },
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\
        \\ const b = @import("b");
    ,
        .{},
        Config{ .allow_line_separated_chunks = false, .severity = .@"error" },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .@"error",
                .slice =
                \\const b = @import("b")
                ,
                .message = "Import 'b' should be grouped with other imports",
                .fix = .{
                    .start = 0,
                    .end = 51,
                    .text =
                    \\ const b = @import("b");
                    \\ const a = @import("a");
                    \\
                    ,
                },
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const import_utils = zlinter.session.imports;
const Ast = std.zig.Ast;
