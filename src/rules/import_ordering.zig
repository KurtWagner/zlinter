//! > [!WARNING]
//! > The `import_ordering` rule is still under testing and development. It may
//! > not work as expected and may change without notice.
//!
//! Enforces a consistent ordering of `@import` declarations in Zig source files.
//!
//! Maintaining a standardized import order improves readability and reduces
//! merge conflicts.
//!
//! `import_ordering` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places.
//!
//! **Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**
//!

// TODO(#52): Add guard code for declarations appearing on same line - just prevent it
// from crashing the lint process, really it shouldn't be happening.

/// Config for import_ordering rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// The order that the imports appear in.
    order: zlinter.rules.LintTextOrder = .alphabetical_ascending,

    /// Whether or not the linter allows imports to be separated by blank
    /// lines (i.e., separate blocks), where each chunk needs to follow the
    /// linter rules or whether they must all follow as a single chunk.
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
        .run = &run,
    };
}

/// Runs the import_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems: shims.ArrayList(zlinter.results.LintProblem) = .empty;
    defer lint_problems.deinit(allocator);

    var scoped_imports = try resolveScopedImports(doc, allocator);
    defer deinitScopedImports(&scoped_imports);

    const tree = doc.handle.tree;
    var import_it = scoped_imports.iterator();
    scopes: while (import_it.next()) |e| {
        var imports = e.value_ptr;
        var previous: ?ImportDecl = null;

        while (imports.removeMinOrNull()) |import| {
            if (previous) |p| {
                const is_same_chunk = (p.last_line + 1) == import.first_line;

                if (!config.allow_line_separated_chunks and !is_same_chunk) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = config.severity,
                        .start = .startOfNode(tree, import.decl_node),
                        .end = .endOfNode(tree, import.decl_node),
                        .message = try std.fmt.allocPrint(allocator, "Import '{s}' should grouped with other imports", .{import.decl_name}),
                        .fix = try swapNodesFix(doc, p.decl_node, import.decl_node, allocator),
                    });
                    continue :scopes;
                }

                if (is_same_chunk) {
                    const order = config.order.cmp(import.decl_name, p.decl_name);
                    if (order == .lt) {
                        try lint_problems.append(allocator, .{
                            .rule_id = rule.rule_id,
                            .severity = config.severity,
                            .start = .startOfNode(tree, import.decl_node),
                            .end = .endOfNode(tree, import.decl_node),
                            .message = try std.fmt.allocPrint(allocator, "Import '{s}' is not in {s} order", .{ import.decl_name, config.order.name() }),
                            .fix = try swapNodesFix(doc, p.decl_node, import.decl_node, allocator),
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
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

// TODO(#52): Write unit tests for helpers and consider whether some should be moved to ast

const ImportsQueueLinesAscending = std.PriorityDequeue(
    ImportDecl,
    void,
    ImportDecl.compareLinesAscending,
);

const ImportDecl = struct {
    decl_node: Ast.Node.Index,
    decl_name: []const u8,
    classification: Classification,
    first_line: usize,
    last_line: usize,

    const Classification = enum { local, external };

    pub fn compareLinesAscending(_: void, a: ImportDecl, b: ImportDecl) std.math.Order {
        return std.math.order(a.first_line, b.first_line);
    }
};

fn deinitScopedImports(scoped_imports: *std.AutoArrayHashMap(Ast.Node.Index, ImportsQueueLinesAscending)) void {
    for (scoped_imports.values()) |v| v.deinit();
    scoped_imports.deinit();
}

fn swapNodesFix(
    doc: zlinter.session.LintDocument,
    first: Ast.Node.Index,
    second: Ast.Node.Index,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!zlinter.results.LintProblemFix {
    const tree = doc.handle.tree;
    const source = tree.source;

    const first_line_start = tree.tokenLocation(0, tree.firstToken(first)).line_start;
    const second_line_start = tree.tokenLocation(0, tree.firstToken(second)).line_start;
    const second_line_end = tree.tokenLocation(0, tree.lastToken(second)).line_end;

    var text = try shims.ArrayList(u8).initCapacity(allocator, second_line_start - first_line_start);
    errdefer text.deinit(allocator);

    if (source[second_line_end] == 0) {
        try text.appendSlice(allocator, source[second_line_start..second_line_end]);
        try text.append(allocator, '\n');
        try text.appendSlice(allocator, source[first_line_start .. second_line_start - 1]);
    } else {
        try text.appendSlice(allocator, source[second_line_start .. second_line_end + 1]);
        try text.appendSlice(allocator, source[first_line_start..second_line_start]);
    }

    return .{
        .text = try text.toOwnedSlice(allocator),
        .start = first_line_start,
        .end = second_line_end + 1,
    };
}

/// Returns declarations initialised as imports grouped by their parent (i.e., their scope).
fn resolveScopedImports(
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
) !std.AutoArrayHashMap(Ast.Node.Index, ImportsQueueLinesAscending) {
    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var node_it = try doc.nodeLineageIterator(root, allocator);
    defer node_it.deinit();

    var scoped_imports: std.AutoArrayHashMap(Ast.Node.Index, ImportsQueueLinesAscending) = .init(allocator);
    while (try node_it.next()) |tuple| {
        const node, const connections = tuple;

        const var_decl = tree.fullVarDecl(node.toNodeIndex()) orelse continue;

        const init_node = NodeIndexShim.initOptional(var_decl.ast.init_node) orelse continue;
        const import_path = isImportCall(tree, init_node.toNodeIndex()) orelse continue;
        const parent = connections.parent orelse continue;

        const decl_name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const classification = classifyImportPath(import_path);

        const first_loc = tree.tokenLocation(0, tree.firstToken(node.toNodeIndex()));
        const last_loc = tree.tokenLocation(0, tree.lastToken(node.toNodeIndex()));

        const import = ImportDecl{
            .decl_node = node.toNodeIndex(),
            .decl_name = decl_name,
            .classification = classification,
            .first_line = first_loc.line,
            .last_line = last_loc.line,
        };

        var gop = try scoped_imports.getOrPut(parent);
        if (gop.found_existing) {
            try gop.value_ptr.add(import);
        } else {
            var imports = ImportsQueueLinesAscending.init(allocator, {});
            errdefer imports.deinit();

            try imports.add(import);
            gop.value_ptr.* = imports;
        }
    }
    return scoped_imports;
}

/// Returns the import path if `@import` built in call.
fn isImportCall(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    switch (shims.nodeTag(tree, node)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const main_token = shims.nodeMainToken(tree, node);
            if (!std.mem.eql(u8, "@import", tree.tokenSlice(main_token))) return null;

            const data = shims.nodeData(tree, node);
            const lhs_node = NodeIndexShim.initOptional(switch (zlinter.version.zig) {
                .@"0.14" => data.lhs,
                .@"0.15" => data.opt_node_and_opt_node[0],
            }) orelse return null;

            std.debug.assert(shims.nodeTag(tree, lhs_node.toNodeIndex()) == .string_literal);

            const lhs_content = tree.tokenSlice(shims.nodeMainToken(tree, lhs_node.toNodeIndex()));
            std.debug.assert(lhs_content.len > 2);
            return lhs_content[1 .. lhs_content.len - 1];
        },
        else => return null,
    }
}

fn classifyImportPath(path: []const u8) ImportDecl.Classification {
    std.debug.assert(path.len > 0);

    if (std.mem.startsWith(u8, path, "./")) return .local;
    if (std.mem.endsWith(u8, path, ".zig")) return .local;
    return .external;
}

// TODO(#52): Move to ast module
// zlinter-disable-next-line
// fn getScopedNode(doc: zlinter.session.LintDocument, node: Ast.Node.Index) Ast.Node.Index {
//     var parent = doc.lineage.items(.parent)[node];
//     while (parent) |parent_node| {
//         switch (shims.nodeTag(doc.handle.tree, parent_node)) {
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
//     return NodeIndexShim.root.toNodeIndex();
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
        Config{ .order = .alphabetical_ascending },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
        \\ const b = @import("b");
        \\ const c = @import("c");
    ,
        Config{
            .order = .alphabetical_descending,
            .allow_line_separated_chunks = false,
        },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const b = @import("b");
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
        Config{ .order = .alphabetical_ascending, .severity = .@"error" },
        &.{.{
            .rule_id = "import_ordering",
            .severity = .@"error",
            .slice =
            \\const b = @import("b");
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
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const c = @import("c");
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
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("a");
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
        Config{ .order = .alphabetical_ascending },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a_main = @import("a");
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
                \\const a_inner = @import("a");
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
                \\const a = @import("a");
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
}

test "allow_line_separated_chunks" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "",
        Config{ .allow_line_separated_chunks = true },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const a = @import("a");
    ,
        Config{ .allow_line_separated_chunks = true },
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = @import("b");
        \\
        \\ const a = @import("a");
    ,
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
        Config{ .allow_line_separated_chunks = false },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .warning,
                .slice =
                \\const a = @import("a");
                ,
                .message = "Import 'a' should grouped with other imports",
                .disabled_by_comment = false,
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
        Config{ .allow_line_separated_chunks = false, .severity = .@"error" },
        &.{
            .{
                .rule_id = "import_ordering",
                .severity = .@"error",
                .slice =
                \\const b = @import("b");
                ,
                .message = "Import 'b' should grouped with other imports",
                .disabled_by_comment = false,
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
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
