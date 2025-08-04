//! Enforces a consistent ordering of @import statements in Zig source files.
//!
//! Maintaining a standardized import order improves readability and reduces merge conflicts.

/// Config for import_ordering rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// The order that the imports appear in.
    order: zlinter.rules.LintTextOrder = .alphabetical_ascending,

    // TODO: Decide whether or not to implement this:
    // /// Whether imports should be at the bottom or top of their parent scope.
    // location: enum { top, bottom, off } = .off,

    // TODO: Decide whether of not to implement this
    // /// Whether or not to group the imports by their visibility or source.
    // group: struct {
    //     /// public and private separately.
    //     visibilty: bool = false,
    //     /// enternal and local separately.
    //     source: bool = false,
    // } = .{},
};

/// Builds and returns the import_ordering rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.import_ordering),
        .run = &run,
    };
}

/// Runs the import_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    _ = config;
    _ = rule;
    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    var scoped_imports = try resolveScopedImports(doc, allocator);
    defer deinitScopedImports(&scoped_imports);

    var import_it = scoped_imports.iterator();
    while (import_it.next()) |e| {
        const scope_node = e.key_ptr.*;
        var imports = e.value_ptr;

        std.debug.print("Scope {d}:\n", .{scope_node});

        while (imports.removeMinOrNull()) |import| {
            std.debug.print(" - {s} is {s} (lines {d} <-> {d})\n", .{
                import.decl_name,
                @tagName(import.classification),
                import.first_line,
                import.last_line,
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(),
        )
    else
        null;
}

const ImportsQueueLinesAscending = std.PriorityDequeue(
    Import,
    void,
    Import.compareLinesAscending,
);

const Import = struct {
    decl_node: std.zig.Ast.Node.Index,
    decl_name: []const u8,
    classification: Classification,
    first_line: usize,
    last_line: usize,

    const Classification = enum { local, external };

    pub fn compareLinesAscending(_: void, a: Import, b: Import) std.math.Order {
        return std.math.order(a.first_line, b.first_line);
    }
};

fn deinitScopedImports(scoped_imports: *std.AutoArrayHashMap(std.zig.Ast.Node.Index, ImportsQueueLinesAscending)) void {
    for (scoped_imports.values()) |v| v.deinit();
    scoped_imports.deinit();
}

/// Returns declarations initialised as imports grouped by their parent (i.e., their scope).
fn resolveScopedImports(
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
) !std.AutoArrayHashMap(std.zig.Ast.Node.Index, ImportsQueueLinesAscending) {
    const tree = doc.handle.tree;

    const root: zlinter.shims.NodeIndexShim = .root;
    var node_it = try doc.nodeLineageIterator(root, allocator);
    defer node_it.deinit();

    var scoped_imports: std.AutoArrayHashMap(std.zig.Ast.Node.Index, ImportsQueueLinesAscending) = .init(allocator);
    while (try node_it.next()) |tuple| {
        const node, const connections = tuple;

        const var_decl = tree.fullVarDecl(node.toNodeIndex()) orelse continue;

        const init_node = zlinter.shims.NodeIndexShim.initOptional(var_decl.ast.init_node) orelse continue;
        const import_path = isImportCall(tree, init_node.toNodeIndex()) orelse continue;
        const parent = connections.parent orelse continue;

        const decl_name = tree.tokenSlice(var_decl.ast.mut_token + 1);
        const classification = classifyImportPath(import_path);

        const first_loc = tree.tokenLocation(0, tree.firstToken(node.toNodeIndex()));
        const last_loc = tree.tokenLocation(0, tree.lastToken(node.toNodeIndex()));

        const import = Import{
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
fn isImportCall(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    switch (zlinter.shims.nodeTag(tree, node)) {
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const main_token = zlinter.shims.nodeMainToken(tree, node);
            if (!std.mem.eql(u8, "@import", tree.tokenSlice(main_token))) return null;

            const data = zlinter.shims.nodeData(tree, node);
            const lhs_node = zlinter.shims.NodeIndexShim.initOptional(switch (zlinter.version.zig) {
                .@"0.14" => data.lhs,
                .@"0.15" => data.opt_node_and_opt_node[0],
            }) orelse return null;

            std.debug.assert(zlinter.shims.nodeTag(tree, lhs_node.toNodeIndex()) == .string_literal);

            const lhs_content = tree.tokenSlice(zlinter.shims.nodeMainToken(tree, lhs_node.toNodeIndex()));
            std.debug.assert(lhs_content.len > 2);
            return lhs_content[1 .. lhs_content.len - 1];
        },
        else => return null,
    }
}

fn classifyImportPath(path: []const u8) Import.Classification {
    std.debug.assert(path.len > 0);

    if (std.mem.startsWith(u8, path, "./")) return .local;
    if (std.mem.endsWith(u8, path, ".zig")) return .local;
    return .external;
}

// TODO: Move to ast module
// zlinter-disable-next-line
// fn getScopedNode(doc: zlinter.session.LintDocument, node: std.zig.Ast.Node.Index) std.zig.Ast.Node.Index {
//     var parent = doc.lineage.items(.parent)[node];
//     while (parent) |parent_node| {
//         switch (zlinter.shims.nodeTag(doc.handle.tree, parent_node)) {
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
//     return zlinter.shims.NodeIndexShim.root.toNodeIndex();
// }

test "import_ordering" {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
