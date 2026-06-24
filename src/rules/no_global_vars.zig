//! Disallows the use of global vars
//! All use of global vars is required to be explicitly enabled with a comment
//!
//! It is also recommended to encapsulate global state into a struct and giving it a instance var:
//! ```
//! const SomeState = struct {
//!    foo: u32,
//!    bar: u64,
//!
//!    // zlinter-disable-next-line no_global_vars - Unfortunately the underlying API relies on global state
//!    var instance: @This() = .{ ... };
//! };
//! ```
//!
//! This keeps the global state still testable, and allows easier migration to local state if possible.

/// Config for no_global_vars rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .@"error",
};

/// Builds and returns the no_global_vars rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return .{
        .rule_id = @tagName(.no_global_vars),
        .run = &run,
    };
}

/// Runs the no_global_vars rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);
    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        var buf: [2]Ast.Node.Index = undefined;
        const parent: Ast.Node.Index = @enumFromInt(index);
        const container = tree.fullContainerDecl(&buf, parent) orelse continue;
        for (container.ast.members) |node| {
            if (!isContainerMemberGlobalVar(tree, node)) continue;
            try lint_problems.append(session_arena, .{
                .start = .startOfNode(tree, node),
                .end = .endOfNode(tree, node),
                .message = try session_arena.dupe(u8, "Global `var` reduces testability and makes the program harder to reason about"),
                .rule_id = rule.rule_id,
                .severity = config.severity,
            });
        }
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

fn isContainerMemberGlobalVar(tree: Ast, node: Ast.Node.Index) bool {
    const decl = tree.fullVarDecl(node) orelse return false;
    return tree.tokenTag(decl.ast.mut_token) == .keyword_var;
}

test {
    std.testing.refAllDecls(@This());
}

test "no_global_vars" {
    const rule = buildRule(.{});
    const source =
        \\var i_am_a_global_var: u32 = 67;
        \\
        \\const Foo = struct {
        \\    var so_am_i: u64 = 69;
        \\    const Bar = enum {
        \\        none,
        \\        var dont_forget_me: ?noreturn = null;
        \\        const im_fine_since_im_no_const: bool = true;
        \\    };
        \\};
        \\
        \\fn me_just_a_fn() void {
        \\    var surely_you_wont_mind_me: ?*anyopaque = null;
        \\    _ = surely_you_wont_mind_me;
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "var i_am_a_global_var: u32 = 67",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "var dont_forget_me: ?noreturn = null",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "var so_am_i: u64 = 69",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

test "no_global_vars - modifier forms" {
    const rule = buildRule(.{});
    const source =
        \\pub var pub_global: u32 = 1;
        \\threadlocal var thread_local_global: u32 = 2;
        \\extern var extern_global: u32;
        \\export var export_global: u32 = 4;
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "pub var pub_global: u32 = 1",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "threadlocal var thread_local_global: u32 = 2",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "extern var extern_global: u32",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "export var export_global: u32 = 4",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
            },
        );
    }
}

test "no_global_vars - nested container vars" {
    const rule = buildRule(.{});
    const source =
        \\const Outer = struct {
        \\    const Inner = struct {
        \\        var nested_global: u32 = 3;
        \\    };
        \\};
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{ .severity = severity },
            &.{
                .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .slice = "var nested_global: u32 = 3",
                    .message = "Global `var` reduces testability and makes the program harder to reason about",
                },
            },
        );
    }
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
