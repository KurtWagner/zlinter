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
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    _ = context;
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (tree.nodeTag(node) != .field_access) continue :nodes;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests and doc.isEnclosedInTestBlock(node)) {
            continue :nodes;
        }

        // unwrap field access lhs and identifier (e.g., lhs.identifier)
        const node_data = tree.nodeData(node);
        const lhs, const identifier = .{ node_data.node_and_token.@"0", node_data.node_and_token.@"1" };

        // is identifier a method on Allocator e.g., something.alloc(..) or something.create(..)
        const is_allocator_method = is_allocator_method: {
            const actual_name = tree.tokenSlice(identifier);
            inline for (@typeInfo(std.mem.Allocator).@"struct".decls) |decl| {
                if (comptime std.meta.hasMethod(std.mem.Allocator, decl.name)) {
                    if (std.mem.eql(u8, actual_name, decl.name)) break :is_allocator_method true;
                }
            }
            break :is_allocator_method false;
        };
        if (!is_allocator_method) continue :nodes;

        const lhs_offset = tree.tokenStart(tree.firstToken(lhs));
        const is_problem = isKnownAllocatorObjectExpr(doc, lhs, lhs_offset, config.detect_allocators, 0);
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
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

fn isKnownAllocatorObjectExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    detect_allocators: []const AllocatorKind,
    depth: u8,
) bool {
    if (depth > 12) return false;
    for (detect_allocators) |allocator_kind| {
        if (!std.mem.endsWith(u8, allocator_kind.file_ends_with, "/std/heap.zig")) continue;
        if (matchesStdHeapAllocatorExpr(doc, node, before_offset, allocator_kind.decl_name, depth + 1)) {
            return true;
        }
    }
    return false;
}

fn matchesStdHeapAllocatorExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    allocator_decl_name: []const u8,
    depth: u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            const ident = tree.getNodeSource(unwrapped);
            const var_decl = semantic.findVarDeclByNameNear(tree, ident, before_offset) orelse return false;
            const init_node = var_decl.ast.init_node.unwrap() orelse return false;
            return matchesStdHeapAllocatorExpr(doc, init_node, before_offset, allocator_decl_name, depth + 1);
        },
        .field_access => {
            const base = tree.nodeData(unwrapped).node_and_token.@"0";
            const field_token = tree.nodeData(unwrapped).node_and_token.@"1";
            const field_name = tree.tokenSlice(field_token);

            if (std.mem.eql(u8, field_name, allocator_decl_name)) {
                return isStdHeapExpr(doc, base, before_offset, depth + 1);
            }
            return false;
        },
        else => return false,
    }
}

fn isStdHeapExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            const ident = tree.getNodeSource(unwrapped);
            const var_decl = semantic.findVarDeclByNameNear(tree, ident, before_offset) orelse return false;
            const init_node = var_decl.ast.init_node.unwrap() orelse return false;
            return isStdHeapExpr(doc, init_node, before_offset, depth + 1);
        },
        .field_access => {
            const base = tree.nodeData(unwrapped).node_and_token.@"0";
            const field_token = tree.nodeData(unwrapped).node_and_token.@"1";
            const field_name = tree.tokenSlice(field_token);
            if (std.mem.eql(u8, field_name, "heap")) {
                return semantic.isStdImportExpr(tree, base, before_offset, depth + 1);
            }
            return false;
        },
        else => return false,
    }
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
const semantic = zlinter.semantic;
