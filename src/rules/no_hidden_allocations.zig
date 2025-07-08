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
    severity: zlinter.LintProblemSeverity = .warning,

    /// Which allocators to detect?
    detect_allocators: []const AllocatorKind = &.{
        .page_allocator,
        .c_allocator,
        .general_purpose_allocator,
        .debug_allocator,
    },

    /// Skip if found within `test { ... }` block
    exclude_tests: bool = true,

    // TODO: Should we check for returned slices/pointers without a deinit contract?
    // check_returned_owned_memory: bool = true,

    // TODO: Should we flag global allocators?
    // detect_global_allocator_use: bool = true,
};

/// Builds and returns the no_hidden_allocations rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.no_hidden_allocations),
        .run = &run,
    };
}

/// Runs the no_hidden_allocations rule.
fn run(
    rule: zlinter.LintRule,
    _: zlinter.LintContext,
    doc: zlinter.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.LintOptions,
) error{OutOfMemory}!?zlinter.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    // 1. Find field access that looks like allocation (e.g., .alloc, .create)
    // 2. Resolve the type of the LHS of the field to determine if its a detected type
    // 3. Profit

    const root: zlinter.shims.NodeIndexShim = .init(0);
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        if (zlinter.shims.nodeTag(tree, node.toNodeIndex()) != .field_access) continue :skip;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests) {
            var next_parent = connections.parent;
            while (next_parent) |parent| {
                if (zlinter.shims.nodeTag(tree, parent) == .test_decl) continue :skip;

                next_parent = doc.lineage.items(.parent)[zlinter.shims.NodeIndexShim.init(parent).index];
            }
        }

        // unwrap field access lhs and identifier (e.g., lhs.identifier)
        const node_data = zlinter.shims.nodeData(tree, node.toNodeIndex());
        const lhs, const identifier = switch (zlinter.version.zig) {
            .@"0.14" => .{ node_data.lhs, node_data.rhs },
            .@"0.15" => .{ node_data.node_and_token.@"0", node_data.node_and_token.@"1" },
        };

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
        if (!is_allocator_method) continue :skip;

        const decl_name, const uri = decl_name_and_uri: {
            if (try doc.analyser.resolveVarDeclAlias(switch (zlinter.version.zig) {
                .@"0.14" => .{ .node = lhs, .handle = doc.handle },
                .@"0.15" => .{ .node_handle = .{ .node = lhs, .handle = doc.handle }, .container_type = null },
            })) |decl_handle| {
                const uri = decl_handle.handle.uri;

                const name: []const u8 = name: switch (decl_handle.decl) {
                    .ast_node => |ast_node| {
                        if (decl_handle.handle.tree.fullVarDecl(ast_node)) |var_decl| {
                            if (zlinter.shims.NodeIndexShim.initOptional(var_decl.ast.init_node)) |init_node| {
                                _ = init_node;
                                //TODO: If .call_one then check return value
                                // std.debug.print("{} - {s}\n", .{
                                //     zlinter.shims.nodeTag(decl_handle.handle.tree, init_node.toNodeIndex()),
                                //     decl_handle.handle.tree.getNodeSource(init_node.toNodeIndex()),
                                // });
                            }

                            const name_token = var_decl.ast.mut_token + 1;
                            break :name decl_handle.handle.tree.tokenSlice(name_token);
                        }
                        break :name null;
                    },
                    else => break :name null,
                } orelse continue :skip;
                break :decl_name_and_uri .{ name, uri };
            } else continue :skip;
        };

        var is_problem: bool = false;
        for (config.detect_allocators) |allocator_kind| {
            if (!std.mem.endsWith(u8, uri, allocator_kind.file_ends_with)) continue;
            if (!std.mem.eql(u8, decl_name, allocator_kind.decl_name)) continue;

            is_problem = true;
            break;
        }
        if (!is_problem) continue :skip;

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node.toNodeIndex()),
            .end = .endOfNode(tree, node.toNodeIndex()),
            .message = try allocator.dupe(u8, "Avoid hidden heap memory management. Instead pass in an Allocator so that the caller knows where memory is being allocated."),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
