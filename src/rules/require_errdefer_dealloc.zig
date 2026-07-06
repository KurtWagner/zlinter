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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    const tree = doc.tree(session);

    var problem_nodes = std.ArrayList(Ast.Node.Index).empty;

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node = tuple[0];

        var buffer: [1]Ast.Node.Index = undefined;
        const fn_decl = zlinter.ast.fnDecl(
            tree,
            node,
            &buffer,
        ) orelse continue :nodes;

        if (!zlinter.ast.fnProtoReturnsError(tree, fn_decl.proto))
            continue :nodes;

        try processBlock(
            session,
            doc,
            fn_decl.block,
            &problem_nodes,
            rule_arena,
        );
    }

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    for (problem_nodes.items) |node|
        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.print("Missing `errdefer` cleanup", .{}),
        });

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

fn processBlock(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    block_node: Ast.Node.Index,
    problems: *std.ArrayList(Ast.Node.Index),
    rule_arena: std.mem.Allocator,
) !void {
    const tree = doc.tree(session);

    // Populated with declarations that look like they should be cleaned up.
    var cleanup_symbols: std.StringHashMap(Ast.Node.Index) = .init(rule_arena);

    var call_buffer: [1]Ast.Node.Index = undefined;

    for (doc.lineage.items(.children)[@intFromEnum(block_node)] orelse &.{}) |child_node|
        if (try declRequiringCleanup(session, doc, rule_arena, child_node)) |decl_ref| {
            try cleanup_symbols.put(
                try rule_arena.dupe(u8, tree.tokenSlice(decl_ref.decl_name_token)),
                child_node,
            );
        } else if (try zlinter.ast.deferBlock(
            doc,
            &session.file_store,
            child_node,
            rule_arena,
        )) |defer_block| {
            // Remove any tracked declarations that are cleaned up within defer/errdefer
            for (defer_block.children) |defer_block_child|
                if (zlinter.ast.findFnCall(
                    doc,
                    &session.file_store,
                    defer_block_child,
                    &call_buffer,
                    &.{"deinit"},
                )) |call| {
                    switch (call.kind) {
                        .single_field => |info| _ = cleanup_symbols.remove(tree.tokenSlice(info.field_main_token)),
                        .enum_literal, .other, .direct => {},
                    }
                };
        } else if (zlinter.ast.isBlock(tree, child_node)) {
            try processBlock(
                session,
                doc,
                child_node,
                problems,
                rule_arena,
            );
        };

    var remaining_it = cleanup_symbols.valueIterator();
    while (remaining_it.next()) |node|
        try problems.append(rule_arena, node.*);
}

const DeclRef = struct {
    decl_name_token: Ast.TokenIndex,
};

/// Returns a declaration reference if the given node is a declaration node
/// that looks like it needs to be cleaned up (e.g., if it has a `deinit` method)
fn declRequiringCleanup(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    rule_arena: std.mem.Allocator,
    maybe_var_decl_node: Ast.Node.Index,
) !?DeclRef {
    const tree = doc.tree(session);
    const var_decl = tree.fullVarDecl(maybe_var_decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    var call_buffer: [1]Ast.Node.Index = undefined;

    // In an attempt to reduce noise we only care if initialized to `empty` or
    // `init` field or through an `init` or `initCapacity` call. I'm torn by
    // this as maybe this rule should just be pedantic with a block list
    // configuration as only those most pedantic would care about this rule?
    if (!switch (tree.nodeTag(init_node)) {
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
            &session.file_store,
            init_node,
            &call_buffer,
            &.{ "init", "initCapacity" },
        )) |call|
            // Try and reduce some noise when using arenas although for anyone
            // using this rule being pedantic and calling deinit on errdefer
            // isnt the absolute worst...?
            !hasNonFreeingAllocatorParam(doc, session, call.params)
        else
            false,
    }) return null;

    const var_decl_id = session.decl_store.declIdByNode(
        doc.file_id,
        maybe_var_decl_node,
    ) orelse return null;
    const deinit_candidates = try session.resolveDeclTypeMemberCandidates(
        rule_arena,
        var_decl_id,
        "deinit",
    );
    for (deinit_candidates) |candidate|
        if (declIsPublicDeinit(session, candidate.decl_id))
            return .{ .decl_name_token = var_decl.ast.mut_token + 1 };

    return null;
}

fn declIsPublicDeinit(
    session: *zlinter.session.LintSession,
    decl_id: zlinter.session.DeclStore.DeclId,
) bool {
    const file_id = session.decl_store.declFileId(decl_id);
    const tree = session.file_store.fileTree(file_id);
    const node = session.decl_store.declAstNode(decl_id) orelse return false;

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(
        &fn_proto_buffer,
        node,
    ) orelse return false;

    return zlinter.ast.fnProtoVisibility(tree, fn_proto) != .private;
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
fn hasNonFreeingAllocatorParam(
    doc: *const zlinter.session.LintDocument,
    session: *const zlinter.session.LintSession,
    params: []const Ast.Node.Index,
) bool {
    const tree = doc.tree(session);
    const skip_var_and_field_names: []const []const u8 = &.{
        "arena",
        "fba",
        "fixed_buffer_allocator",
        "arena_allocator",
    };
    var call_buffer: [1]Ast.Node.Index = undefined;
    for (params) |param_node| {
        const tag = tree.nodeTag(param_node);
        switch (tag) {
            .identifier => {
                const slice = tree.tokenSlice(tree.nodeMainToken(param_node));
                for (skip_var_and_field_names) |str|
                    if (std.mem.eql(u8, slice, str)) return true;
            },
            .field_access => if (zlinter.ast.isFieldVarAccess(tree, param_node, skip_var_and_field_names)) return true,
            else => if (zlinter.ast.fnCall(
                doc,
                &session.file_store,
                param_node,
                &call_buffer,
                &.{"allocator"},
            )) |call| {
                switch (call.kind) {
                    // e.g., checking for `arena.allocator()` call. Unfortunately
                    // currently won't capture deeply nested, like `parent.arena.allocator()`
                    // but this seems super unlikely so who cares for a linter...
                    .single_field => |info| for (skip_var_and_field_names) |str|
                        if (std.mem.eql(u8, tree.tokenSlice(info.field_main_token), str))
                            return true,
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

        defer _ = arena.reset(.retain_capacity);

        var session = zlinter.testing.initFakeContext(arena.allocator(), std.testing.io);

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try zlinter.testing.loadFakeDocument(
            &session,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        );
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        const tree = doc.tree(&session);
        const actual = hasNonFreeingAllocatorParam(
            doc,
            &session,
            tree.fullCall(&buffer, try zlinter.testing.expectNodeOfTagFirst(
                &session,
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
const Ast = std.zig.Ast;
