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
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (shims.nodeTag(tree, node.toNodeIndex()) != .field_access) continue :nodes;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests and doc.isEnclosedInTestBlock(node)) {
            continue :nodes;
        }

        // unwrap field access lhs and identifier (e.g., lhs.identifier)
        const node_data = shims.nodeData(tree, node.toNodeIndex());
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

        const decl_name, const uri = decl_name_and_uri: {
            if (try context.analyser.resolveVarDeclAlias(
                .{
                    .decl = .{ .ast_node = lhs },
                    .handle = doc.handle,
                    .container_type = null,
                },
            )) |decl_handle| {
                const uri = decl_handle.handle.uri;

                const name: []const u8 = name: switch (decl_handle.decl) {
                    .ast_node => |ast_node| {
                        if (decl_handle.handle.tree.fullVarDecl(ast_node)) |var_decl| {
                            if (NodeIndexShim.initOptional(var_decl.ast.init_node)) |init_node| {
                                _ = init_node;
                                // TODO: If .call_one then check return value
                                // std.debug.print("{} - {s}\n", .{
                                //     shims.nodeTag(decl_handle.handle.tree, init_node.toNodeIndex()),
                                //     decl_handle.handle.tree.getNodeSource(init_node.toNodeIndex()),
                                // });
                            }

                            const name_token = var_decl.ast.mut_token + 1;
                            break :name decl_handle.handle.tree.tokenSlice(name_token);
                        }
                        break :name null;
                    },
                    else => break :name null,
                } orelse continue :nodes;
                break :decl_name_and_uri .{ name, uri };
            } else continue :nodes;
        };

        var is_problem: bool = false;
        for (config.detect_allocators) |allocator_kind| {
            if (!std.mem.endsWith(u8, uri.raw, allocator_kind.file_ends_with)) continue;
            if (!std.mem.eql(u8, decl_name, allocator_kind.decl_name)) continue;

            is_problem = true;
            break;
        }
        if (!is_problem) continue :nodes;

        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node.toNodeIndex()),
            .end = .endOfNode(tree, node.toNodeIndex()),
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

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
