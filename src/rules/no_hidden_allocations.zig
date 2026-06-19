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
        .execution = .compile_context,
        .run = &run,
    };
}

/// Runs the no_hidden_allocations rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (tree.nodeTag(node) != .field_access) continue :nodes;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node)) {
            continue :nodes;
        }

        // unwrap field access lhs and identifier (e.g., lhs.identifier)
        const node_data = tree.nodeData(node);
        const lhs, const identifier = .{ node_data.node_and_token.@"0", node_data.node_and_token.@"1" };

        // is identifier a method on Allocator e.g., something.alloc(..) or something.create(..)
        const is_allocator_method = is_allocator_method: {
            const actual_name = tree.tokenSlice(identifier);
            inline for (@typeInfo(std.mem.Allocator).@"struct".decl_names) |decl_name| {
                if (comptime std.meta.hasMethod(std.mem.Allocator, decl_name)) {
                    if (std.mem.eql(u8, actual_name, decl_name)) break :is_allocator_method true;
                }
            }
            break :is_allocator_method false;
        };
        if (!is_allocator_method) continue :nodes;

        const decl_id = resolveAllocatorDecl(
            session,
            doc,
            lhs,
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

        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try gpa.dupe(u8, "Avoid hidden heap memory management. Instead pass in an Allocator so that the caller knows where memory is being allocated."),
        });
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

fn resolveAllocatorDecl(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    lhs: Ast.Node.Index,
) ?zlinter.session.DeclStore.DeclId {
    const decl_id = session.resolveDeclOfNode(doc, lhs) orelse return null;
    return resolveDeclAlias(session, decl_id);
}

/// Allocators are often reached through local aliases.
///
/// For example,
///
/// ```
/// const heap = std.heap;
/// const allocator = heap.page_allocator;
/// allocator.alloc(...);
/// ```
///
/// This function walks `allocator` -> `heap.page_allocator` -> `std.heap.page_allocator`
/// so detection is based on the original allocator declaration, not the
/// alias declarations or their common `std.mem.Allocator` type.
fn resolveDeclAlias(
    session: *zlinter.session.LintSession,
    decl_id: zlinter.session.DeclStore.DeclId,
) zlinter.session.DeclStore.DeclId {
    var current_decl_id = decl_id;
    var remaining_alias_depth: u8 = 16; // Cap to avoid getting caught in a loop.

    while (remaining_alias_depth > 0) : (remaining_alias_depth -= 1) {
        const file_id = session.decl_store.declFileId(current_decl_id);
        const tree = session.file_store.fileTree(file_id);
        const decl_node = session.decl_store.declAstNode(current_decl_id) orelse return current_decl_id;
        const var_decl = tree.fullVarDecl(decl_node) orelse return current_decl_id;
        const init_node = var_decl.ast.init_node.unwrap() orelse return current_decl_id;
        const target_decl_id = session.decl_store.resolveNodeDecl(
            &session.file_store,
            &session.module_store,
            current_decl_id,
            init_node,
        ) orelse return current_decl_id;

        if (target_decl_id == current_decl_id) return current_decl_id;
        current_decl_id = target_decl_id;
    }

    return current_decl_id;
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

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
