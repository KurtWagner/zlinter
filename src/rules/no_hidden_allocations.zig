//! Avoid encapsulating hidden heap allocations inside functions without
//! requiring the caller to pass an allocator.
//!
//! The caller should decide where and when to allocate not the callee.

pub const AllocatorKind = struct {
    file_ends_with: []const u8 = "/std/heap.zig",
    decl_name: []const u8 = "c_allocator",

    pub const page_allocator: AllocatorKind = .init("/std/heap.zig", "page_allocator");
    pub const c_allocator: AllocatorKind = .init("/std/heap.zig", "c_allocator");
    pub const general_purpose_allocator: AllocatorKind = .init("/std/heap.zig", "GeneralPurposeAllocator");
    pub const debug_allocator: AllocatorKind = .init("/std/heap.zig", "DebugAllocator");

    pub fn init(file_ends_with: []const u8, decl_name: []const u8) AllocatorKind {
        return .{ .file_ends_with = file_ends_with, .decl_name = decl_name };
    }
};

/// Config for no_hidden_allocations rule.
pub const Config = struct {
    /// The severity of hidden allocations (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// What kinds of allocators to detect.
    detect_allocators: []const AllocatorKind = &.{
        .page_allocator,
        .c_allocator,
        .general_purpose_allocator,
        .debug_allocator,
    },

    /// Skip if found within `test { ... }` block.
    exclude_tests: bool = true,

    // TODO: Should we flag global allocators?
    // detect_global_allocator_use: bool = true,
};

/// Builds and returns the no_hidden_allocations rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_hidden_allocations),
        .run = &run,
    };
}

/// Runs the no_hidden_allocations rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;
    const rule_arena = session.runtime.ruleArena();

    const session_arena = session.runtime.sessionArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (tree.nodeTag(node) != .field_access) continue :nodes;

        const call_node = isCalleeOfCall(tree, doc, node) orelse continue :nodes;
        _ = call_node;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) {
            continue :nodes;
        }

        // unwrap field access lhs and identifier (e.g., lhs.identifier)
        const node_data = tree.nodeData(node);
        const lhs, const identifier = .{
            node_data.node_and_token.@"0",
            node_data.node_and_token.@"1",
        };

        // is identifier a method on Allocator e.g., something.alloc(..) or something.create(..)
        const is_allocator_method = is_allocator_method: {
            const actual_name = tree.tokenSlice(identifier);
            inline for (@typeInfo(std.mem.Allocator).@"struct".decl_names) |decl_name| {
                if (comptime std.meta.hasMethod(std.mem.Allocator, decl_name)) {
                    if (std.mem.eql(u8, actual_name, decl_name))
                        break :is_allocator_method true;
                }
            }
            break :is_allocator_method false;
        };
        if (!is_allocator_method) continue :nodes;

        const decl_id = resolveAllocatorDecl(
            session,
            doc,
            unwrapGroupedExpression(tree, lhs),
        ) orelse continue :nodes;
        const decl_file_id = session.decl_store.declFileId(decl_id);
        const decl_tree = session.file_store.fileTree(decl_file_id);
        const decl_name_token = session.decl_store.declNameToken(decl_id) orelse
            continue :nodes;
        const decl_name = decl_tree.tokenSlice(decl_name_token);
        const decl_abs_path = session.file_store.fileAbsPath(decl_file_id);

        var is_problem: bool = false;
        for (config.detect_allocators) |allocator_kind| {
            if (!pathEndsWith(decl_abs_path, allocator_kind.file_ends_with)) continue;
            if (!std.mem.eql(u8, decl_name, allocator_kind.decl_name)) continue;

            is_problem = true;
            break;
        }
        if (!is_problem) continue :nodes;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.dupe(u8, "Avoid hidden heap memory management. Instead pass in an Allocator so that the caller knows where memory is being allocated."),
        });
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

fn isCalleeOfCall(
    tree: Ast,
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
) ?Ast.Node.Index {
    var current = node;
    var ancestors = doc.nodeAncestorIterator(node);
    while (ancestors.next()) |parent| {
        var call_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullCall(&call_buffer, parent)) |call| {
            return if (call.ast.fn_expr == current) parent else null;
        }
        current = parent;
    }

    return null;
}

fn resolveAllocatorDecl(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    lhs: Ast.Node.Index,
) ?zlinter.session.DeclStore.DeclId {
    const rule_arena = session.runtime.ruleArena();
    const decl_candidates = session.resolveDeclCandidatesOfNode(rule_arena, doc, lhs) catch return null;

    for (decl_candidates) |candidate| {
        return session.resolveDeclAliasCandidate(candidate).decl_id;
    }
    return null;
}

fn unwrapGroupedExpression(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    var current = node;
    while (tree.nodeTag(current) == .grouped_expression) {
        current = tree.nodeData(current).node_and_token[0];
    }
    return current;
}

fn pathEndsWith(path: []const u8, suffix: []const u8) bool {
    if (suffix.len > path.len) return false;

    const offset = path.len - suffix.len;
    for (suffix, 0..) |suffix_char, i| {
        const path_char = path[offset + i];

        if (isPathSep(path_char) and isPathSep(suffix_char)) continue;
        if (path_char != suffix_char) return false;
    }

    return true;
}

fn isPathSep(char: u8) bool {
    return char == std.fs.path.sep_posix or char == std.fs.path.sep_windows;
}

test pathEndsWith {
    try std.testing.expect(pathEndsWith("/opt/zig/lib/std/heap.zig", "/std/heap.zig"));
    try std.testing.expect(pathEndsWith("/opt/zig/lib/std/heap.zig", "heap.zig"));
    try std.testing.expect(pathEndsWith("D:\\zig\\lib\\std\\heap.zig", "/std/heap.zig"));
    try std.testing.expect(pathEndsWith("/opt/zig/lib/std/heap.zig", "\\std\\heap.zig"));
    try std.testing.expect(!pathEndsWith("/opt/zig/lib/std/mem.zig", "/std/heap.zig"));
    try std.testing.expect(!pathEndsWith("/opt/zig/lib/my_std/heap.zig", "/std/heap.zig"));
    try std.testing.expect(!pathEndsWith("/lib/my_std/heap.zig", "/opt/zig/lib/my_std/heap.zig"));
}

test "no_hidden_allocations ignores allocator method references" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\fn main() void {
        \\    const alloc_fn = std.heap.page_allocator.alloc;
        \\    _ = std.heap.page_allocator.alloc;
        \\    _ = alloc_fn;
        \\}
        \\
        \\test {
        \\    const alloc_fn = std.heap.page_allocator.alloc;
        \\    _ = alloc_fn;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
