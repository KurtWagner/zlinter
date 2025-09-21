//! > [!WARNING]
//! > The `require_errdefer_dealloc` rule is still under testing and development.
//! > It may not work as expected and may change without notice.
//!
//! Ensure that any allocation made within a function that can return an error
//! is paired with `errdefer`, unless the resource is already being released in
//! a `defer` block.
//!
//! **Why?**
//!
//! If a function returns an error, it's signaling a recoverable condition
//! within the application's normal control flow. Failing to perform cleanup
//! in these cases can lead to memory leaks.
//!
//! **Caveats:**
//!
//! * This rule is not exhaustive. It makes a best-effort attempt to detect known
//!   object declarations that require cleanup.
//!
//! * This rule cannot always reliably detect usage of fixed buffer allocators or
//!   arenas; however, using `errdefer array.deinit(arena);` in these cases is
//!   generally harmless. It will do its best to ignore the most obvious cases.
//!
//! **Example:**
//!
//! ```zig
//! // Bad: On success, returns an owned slice the caller must free; on error, memory is leaked.
//! pub fn message(age: u8, allocator: std.mem.Allocator) error{ OutOfMemory, InvalidAge }![]const u8 {
//!     var parts = std.ArrayList(u8).init(allocator);
//!
//!     try parts.appendSlice("You are ");
//!     if (age > 18)
//!         try parts.appendSlice("an adult")
//!     else if (age > 0)
//!         try parts.appendSlice("not an adult")
//!     else
//!         return error.InvalidAge;
//!
//!     return parts.toOwnedSlice();
//! }
//! ```
//!

/// Config for require_errdefer_dealloc rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the require_errdefer_dealloc rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_errdefer_dealloc),
        .run = &run,
    };
}

/// Runs the require_errdefer_dealloc rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const tree = doc.handle.tree;

    var problem_nodes = shims.ArrayList(Ast.Node.Index).empty;
    defer problem_nodes.deinit(gpa);

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(
        root,
        gpa,
    );
    defer it.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    nodes: while (try it.next()) |tuple| {
        const node = tuple[0].toNodeIndex();

        var buffer: [1]Ast.Node.Index = undefined;
        const fn_decl = zlinter.ast.fnDecl(
            tree,
            node,
            &buffer,
        ) orelse continue :nodes;

        if (!zlinter.ast.fnProtoReturnsError(tree, fn_decl.proto))
            continue :nodes;

        try processBlock(
            doc,
            fn_decl.block,
            &problem_nodes,
            gpa,
            arena.allocator(),
        );

        _ = arena.reset(.retain_capacity);
    }

    var lint_problems: shims.ArrayList(zlinter.results.LintProblem) = .empty;
    defer lint_problems.deinit(gpa);

    for (problem_nodes.items) |node| {
        try lint_problems.append(gpa, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try std.fmt.allocPrint(gpa, "Missing `errdefer` cleanup", .{}),
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

fn processBlock(
    doc: zlinter.session.LintDocument,
    block_node: Ast.Node.Index,
    problems: *shims.ArrayList(Ast.Node.Index),
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
) !void {
    const tree = doc.handle.tree;

    // Populated with declarations that look like they should be cleaned up.
    var cleanup_symbols: std.StringHashMap(Ast.Node.Index) = .init(arena);

    var call_buffer: [1]Ast.Node.Index = undefined;

    for (doc.lineage.items(.children)[NodeIndexShim.init(block_node).index] orelse &.{}) |child_node| {
        if (try declRequiringCleanup(doc, child_node)) |decl_ref| {
            try cleanup_symbols.put(
                try arena.dupe(u8, doc.handle.tree.tokenSlice(decl_ref.decl_name_token)),
                child_node,
            );
        } else if (try zlinter.ast.deferBlock(
            doc,
            child_node,
            arena,
        )) |defer_block| {
            // Remove any tracked declarations that are cleaned up within defer/errdefer
            for (defer_block.children) |defer_block_child| {
                if (zlinter.ast.findFnCall(
                    doc,
                    defer_block_child,
                    &call_buffer,
                    &.{"deinit"},
                )) |call| {
                    switch (call.kind) {
                        .single_field => |info| {
                            _ = cleanup_symbols.remove(tree.tokenSlice(info.field_main_token));
                        },
                        .enum_literal, .other, .direct => {},
                    }
                }
            }
        } else if (zlinter.ast.isBlock(tree, child_node)) {
            try processBlock(
                doc,
                child_node,
                problems,
                gpa,
                arena,
            );
        }
    }

    var remaining_it = cleanup_symbols.valueIterator();
    while (remaining_it.next()) |node| {
        try problems.append(gpa, node.*);
    }
}

const DeclRef = struct {
    decl_name_token: Ast.TokenIndex,
};

/// Returns a declaration reference if the given node is a declaration node
/// that looks like it needs to be cleaned up (e.g., if it has a `deinit` method)
fn declRequiringCleanup(doc: zlinter.session.LintDocument, maybe_var_decl_node: Ast.Node.Index) !?DeclRef {
    const tree = doc.handle.tree;
    const var_decl = tree.fullVarDecl(maybe_var_decl_node) orelse return null;
    const init_node = (NodeIndexShim.initOptional(var_decl.ast.init_node) orelse
        return null).toNodeIndex();
    var call_buffer: [1]Ast.Node.Index = undefined;

    // In an attempt to reduce noise we only care if initialized to `empty` or
    // `init` field or through an `init` or `initCapacity` call. I'm torn by
    // this as maybe this rule should just be pedantic with a block list
    // configuration as only those most pedantic would care about this rule?
    if (!switch (shims.nodeTag(tree, init_node)) {
        // e.g., `ArrayList(u8).empty`
        .field_access => zlinter.ast.isFieldVarAccess(
            tree,
            init_node,
            &.{ "empty", "init" },
        ),
        // e.g., `.empty`
        .enum_literal => zlinter.ast.isEnumLiteral(
            tree,
            init_node,
            &.{ "empty", "init" },
        ),
        else => if (zlinter.ast.fnCall(
            doc,
            init_node,
            &call_buffer,
            &.{ "init", "initCapacity" },
        )) |call|
            // Try and reduce some noise when using arenas although for anyone
            // using this rule being pedantic and calling deinit on errdefer
            // isnt the absolute worst...?
            !hasNonFreeingAllocatorParam(doc, call.params)
        else
            false,
    }) return null;

    const var_decl_type = try doc.resolveTypeOfNode(maybe_var_decl_node) orelse return null;
    switch (var_decl_type.data) {
        .container => |container| {
            const scope_handle = switch (zlinter.version.zig) {
                .@"0.14" => container,
                .@"0.15", .@"0.16" => container.scope_handle,
            };
            const node = scope_handle.toNode();
            const tag = shims.nodeTag(scope_handle.handle.tree, node);
            switch (tag) {
                .container_decl,
                .container_decl_arg,
                .container_decl_arg_trailing,
                .container_decl_trailing,
                .container_decl_two,
                .container_decl_two_trailing,
                => {
                    const scope_tree = scope_handle.handle.tree;

                    const has_deinit_method: bool = has_deinit_method: {
                        var buffer: [2]Ast.Node.Index = undefined;
                        const container_decl = scope_tree.fullContainerDecl(&buffer, node).?;
                        for (container_decl.ast.members) |member| {
                            var fn_proto_buffer: [1]Ast.Node.Index = undefined;
                            const fn_decl = zlinter.ast.fnDecl(scope_tree, member, &fn_proto_buffer) orelse continue;

                            if (zlinter.ast.fnProtoVisibility(scope_tree, fn_decl.proto) == .private) continue;

                            const name_token = fn_decl.proto.name_token orelse continue;
                            const name = scope_tree.tokenSlice(name_token);

                            if (std.mem.eql(u8, name, "deinit")) break :has_deinit_method true;
                        }
                        break :has_deinit_method false;
                    };
                    if (!has_deinit_method) return null;

                    return .{ .decl_name_token = var_decl.ast.mut_token + 1 };
                },
                else => {},
            }
        },
        else => {},
    }

    return null;
}

/// Returns true if it looks like based on parameters that the given call use
/// leveraging an arena like allocator and thus should be excluded from checks
/// by `require_errdefer_dealloc`.
///
/// For example, `.init(arena.allocator())` or `.init(arena)` look like they're
/// accepting an arena so requiring cleanup in `errdefer` is not strictly necessary
/// and may even cause confuion.
///
/// Where as `.init(allocator)` or `.init(std.heap.c_allocator)` should be checked
/// for stricter cleanup on error as it won't automatically clear itself.
fn hasNonFreeingAllocatorParam(doc: zlinter.session.LintDocument, params: []const Ast.Node.Index) bool {
    const tree = doc.handle.tree;
    const skip_var_and_field_names: []const []const u8 = &.{
        "arena",
        "fba",
        "fixed_buffer_allocator",
        "arena_allocator",
    };
    var call_buffer: [1]Ast.Node.Index = undefined;
    for (params) |param_node| {
        const tag = shims.nodeTag(tree, param_node);
        switch (tag) {
            .identifier => {
                const slice = tree.tokenSlice(shims.nodeMainToken(tree, param_node));
                for (skip_var_and_field_names) |str| {
                    if (std.mem.eql(u8, slice, str)) return true;
                }
            },
            .field_access => if (zlinter.ast.isFieldVarAccess(tree, param_node, skip_var_and_field_names)) return true,
            else => if (zlinter.ast.fnCall(doc, param_node, &call_buffer, &.{"allocator"})) |call| {
                switch (call.kind) {
                    // e.g., checking for `arena.allocator()` call. Unfortunately
                    // currently won't capture deeply nested, like `parent.arena.allocator()`
                    // but this seems super unlikely so who cares for a linter...
                    .single_field => |info| {
                        for (skip_var_and_field_names) |str|
                            if (std.mem.eql(u8, tree.tokenSlice(info.field_main_token), str)) return true;
                    },
                    .enum_literal, .other, .direct => {},
                }
            },
        }
    }
    return false;
}

test "hasNonFreeingAllocatorParam" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var buffer: [1]Ast.Node.Index = undefined;
    inline for (&.{
        .{
            \\ var a = .init();
            ,
            false,
        },
        .{
            \\ var a = .init(allocator);
            ,
            false,
        },
        .{
            \\ var a = .init(std.heap.c_allocator);
            ,
            false,
        },
        .{
            \\ var a = .init(gpa);
            ,
            false,
        },
        .{
            \\ var a = .init(arena);
            ,
            true,
        },
        .{
            \\ var a = .init(arena_allocator);
            ,
            true,
        },
        .{
            \\ var a = .init(fixed_buffer_allocator);
            ,
            true,
        },
        .{
            \\ var a = .init(fba);
            ,
            true,
        },
        .{
            \\ var a = .init(arena.allocator());
            ,
            true,
        },
        .{
            \\ var a = .init(fba.allocator());
            ,
            true,
        },
        .{
            \\ var a = .init(fixed_buffer_allocator.allocator());
            ,
            true,
        },
    }) |tuple| {
        const source, const expected = tuple;
        errdefer std.debug.print("Failed source: '{s}' expected {?}\n", .{ source, expected });

        defer _ = arena.reset(.retain_capacity);

        var ctx: zlinter.session.LintContext = undefined;
        try ctx.init(.{}, std.testing.allocator);
        defer ctx.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var doc = (try zlinter.testing.loadFakeDocument(
            &ctx,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        )).?;
        defer doc.deinit(ctx.gpa);

        const tree = doc.handle.tree;
        const actual = hasNonFreeingAllocatorParam(
            doc,
            tree.fullCall(&buffer, try zlinter.testing.expectNodeOfTagFirst(
                doc,
                &.{
                    .call,
                    .call_comma,
                    .call_one,
                    .call_one_comma,
                },
            )).?.ast.params,
        );
        try std.testing.expectEqual(expected, actual);
    }
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
