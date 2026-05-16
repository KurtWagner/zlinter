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
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const tree = doc.handle.tree;

    var problem_nodes = std.ArrayList(Ast.Node.Index).empty;
    defer problem_nodes.deinit(gpa);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(
        root,
        gpa,
    );
    defer it.deinit();

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

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
            context,
            doc,
            fn_decl.block,
            &problem_nodes,
            gpa,
            arena.allocator(),
        );

        _ = arena.reset(.retain_capacity);
    }

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
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
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    block_node: Ast.Node.Index,
    problems: *std.ArrayList(Ast.Node.Index),
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
) !void {
    const tree = doc.handle.tree;

    // Populated with declarations that look like they should be cleaned up.
    var cleanup_symbols: std.StringHashMap(Ast.Node.Index) = .init(arena);

    var call_buffer: [1]Ast.Node.Index = undefined;

    for (doc.lineage.items(.children)[@intFromEnum(block_node)] orelse &.{}) |child_node| {
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
                context,
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
fn declRequiringCleanup(
    doc: *const zlinter.session.LintDocument,
    maybe_var_decl_node: Ast.Node.Index,
) !?DeclRef {
    const tree = doc.handle.tree;
    const var_decl = tree.fullVarDecl(maybe_var_decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    var call_buffer: [1]Ast.Node.Index = undefined;

    // In an attempt to reduce noise we only care about init-like calls that
    // also look allocator-backed, or managed-style `.empty` aliases.
    if (!switch (tree.nodeTag(init_node)) {
        // e.g., `AutoHashMapUnmanaged(...).empty`
        .field_access => isLikelyManagedEmptyInit(tree, var_decl, init_node),
        // e.g., `.empty` with explicit managed-style type annotation
        .enum_literal => isLikelyManagedEmptyInit(tree, var_decl, init_node),
        else => if (zlinter.ast.fnCall(
            doc,
            init_node,
            &call_buffer,
            &.{ "init", "initCapacity" },
        )) |call|
            hasLikelyOwningAllocatorParam(doc, call.params) and
            // Try and reduce some noise when using arenas although for anyone
            // using this rule being pedantic and calling deinit on errdefer
            // isnt the absolute worst...?
            !hasNonFreeingAllocatorParam(doc, call.params) and
                !hasBorrowedBufferParam(doc, call.params)
        else
            false,
    }) return null;

    return .{ .decl_name_token = var_decl.ast.mut_token + 1 };
}

fn hasLikelyOwningAllocatorParam(doc: *const zlinter.session.LintDocument, params: []const Ast.Node.Index) bool {
    const tree = doc.handle.tree;
    var call_buffer: [1]Ast.Node.Index = undefined;
    var found_ambiguous_single_param = false;
    for (params) |param_node| {
        const unwrapped = zlinter.ast.unwrapNode(tree, param_node, .{
            .unwrap_optional_unwrap = false,
        });
        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                if (std.mem.eql(u8, name, "allocator") or
                    std.mem.eql(u8, name, "gpa") or
                    std.mem.endsWith(u8, name, "_allocator"))
                {
                    return true;
                }

                found_ambiguous_single_param = true;
            },
            .field_access => {
                if (zlinter.ast.isFieldVarAccess(tree, unwrapped, &.{ "allocator", "c_allocator", "page_allocator" })) {
                    return true;
                }
                found_ambiguous_single_param = true;
            },
            else => if (zlinter.ast.fnCall(doc, unwrapped, &call_buffer, &.{"allocator"})) |_| {
                return true;
            } else {
                found_ambiguous_single_param = true;
            },
        }
    }
    // Keep a conservative signal for single-arg init calls where the argument
    // name is ambiguous but often allocator-like in practice.
    return params.len == 1 and found_ambiguous_single_param;
}

fn isLikelyManagedEmptyInit(tree: Ast, var_decl: Ast.full.VarDecl, init_node: Ast.Node.Index) bool {
    const field_name = switch (tree.nodeTag(init_node)) {
        .field_access => tree.tokenSlice(tree.lastToken(init_node)),
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(init_node)),
        else => return false,
    };
    if (!(std.mem.eql(u8, field_name, "empty") or std.mem.eql(u8, field_name, "init"))) return false;

    if (var_decl.ast.type_node.unwrap()) |type_node| {
        const type_source = tree.getNodeSource(zlinter.ast.unwrapNode(tree, type_node, .{}));
        if (containsAsciiIgnoreCase(type_source, "managed")) return true;
    }

    if (tree.nodeTag(init_node) == .field_access) {
        const lhs = tree.nodeData(init_node).node_and_token.@"0";
        const lhs_source = tree.getNodeSource(zlinter.ast.unwrapNode(tree, lhs, .{}));
        if (containsAsciiIgnoreCase(lhs_source, "managed")) return true;
    }

    return false;
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
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
fn hasNonFreeingAllocatorParam(doc: *const zlinter.session.LintDocument, params: []const Ast.Node.Index) bool {
    const tree = doc.handle.tree;
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

/// Returns true if params indicate a fixed/borrowed buffer style initializer
/// (e.g. `.init(&buffer)`), which typically should not require errdefer cleanup.
fn hasBorrowedBufferParam(doc: *const zlinter.session.LintDocument, params: []const Ast.Node.Index) bool {
    const tree = doc.handle.tree;
    for (params) |param_node| {
        const unwrapped = zlinter.ast.unwrapNode(tree, param_node, .{
            .unwrap_optional_unwrap = false,
        });
        switch (tree.nodeTag(unwrapped)) {
            .address_of => return true,
            else => {},
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
        errdefer std.debug.print("Failed source: '{s}' expected {}\n", .{ source, expected });

        defer _ = arena.reset(.retain_capacity);

        const environ_map: std.process.Environ.Map = .init(arena.allocator());

        var context: zlinter.session.LintContext = undefined;
        try context.init(std.testing.io, &environ_map, std.testing.allocator);
        defer context.deinit();

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try zlinter.testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            "fn main() void {\n" ++ source ++ "\n}",
            arena.allocator(),
        );

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

test "require_errdefer_dealloc - ignores init call without allocator-like params" {
    const source: [:0]const u8 =
        \\const ChildIterator = struct {
        \\  fn init(_: u8, _: u8) ChildIterator {
        \\    return .{};
        \\  }
        \\};
        \\
        \\fn parse() !void {
        \\  var it = ChildIterator.init(1, 2);
        \\  _ = &it;
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .severity = .@"error" },
        &.{},
    );
}

test "require_errdefer_dealloc - ignores .empty field alias init" {
    const source: [:0]const u8 =
        \\const Context = struct {
        \\  pub const empty: Context = .{};
        \\};
        \\
        \\fn parse() !void {
        \\  var ctx = Context.empty;
        \\  _ = &ctx;
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .severity = .@"error" },
        &.{},
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
