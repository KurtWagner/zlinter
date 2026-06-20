//! Require explicit exhaustiveness for switches over exhaustive enums.
//!
//! This rule ensures switches over exhaustive enums remain explicit as the code evolves.
//! When a new enum tag is introduced, a switch that uses `else` can continue compiling while
//! unintentionally routing the new value through unintended logic. This hides missing behavior and
//! makes such changes easy to overlook during testing and review.
//!
//! Requiring every tag to be listed forces the author to decide how each value should be handled.
//! This keeps control flow intentional, improves readability, and prevents silently mis-handling
//! newly added enum values.
//!
//! **Good:**
//!
//! ```zig
//! const State = enum { idle, running, stopped };
//! fn handle(state: State) void {
//!     switch (state) {
//!         .idle => {},
//!         .running => {},
//!         .stopped => {},
//!     }
//! }
//! ```
//!
//! **Bad (else on exhaustive enum):**
//!
//! ```zig
//! const State = enum { idle, running, stopped };
//! fn handle(state: State) void {
//!     switch (state) {
//!         .idle => {},
//!         .running => {},
//!         else => {},
//!     }
//! }
//! ```

/// Config for require_exhaustive_enum_switch rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the require_exhaustive_enum_switch rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_exhaustive_enum_switch),
        .execution = .compile_context,
        .run = &run,
    };
}

/// Runs the require_exhaustive_enum_switch rule.
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
    defer lint_problems.deinit(session_arena);

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, session_arena);
    defer it.deinit();

    // Holds all tags within an enum used in a switch statement
    var complete_tag_set: std.StringHashMap(void) = .init(session_arena);
    defer complete_tag_set.deinit();

    // Tracks only the used enum tags within a switch statement
    var used_tag_set = std.StringHashMap(void).init(session_arena);
    defer used_tag_set.deinit();

    var missing_tags: std.ArrayList([]const u8) = .empty;
    defer missing_tags.deinit(session_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const switch_info = tree.fullSwitch(node) orelse continue :nodes;

        const switch_expr_enum_decl = session.resolveEnumDeclOfNode(doc, switch_info.ast.condition) orelse continue :nodes;

        const switch_expr_enum = session.enumInfo(switch_expr_enum_decl) orelse continue :nodes;
        if (switch_expr_enum.is_non_exhaustive) continue :nodes;

        var enum_member_buffer: [2]Ast.Node.Index = undefined;
        const enum_container_decl = switch_expr_enum.containerDecl(session, &enum_member_buffer) orelse continue :nodes;
        const enum_members = enum_container_decl.ast.members;
        if (enum_members.len == 0) continue :nodes;

        defer complete_tag_set.clearRetainingCapacity();
        try complete_tag_set.ensureTotalCapacity(@intCast(enum_members.len));
        for (enum_members) |member| {
            if (switch_expr_enum.tagName(session, member)) |tag|
                complete_tag_set.putAssumeCapacity(tag, {});
        }

        // Set if an else case exists in switch
        var else_case_node: ?Ast.Node.Index = null;

        defer used_tag_set.clearRetainingCapacity();
        for (switch_info.ast.cases) |case_node| {
            const switch_case = tree.fullSwitchCase(case_node).?;

            if (switch_case.ast.values.len == 0) {
                if (else_case_node == null) else_case_node = case_node;
            } else {
                case_values: for (switch_case.ast.values) |value_node| {
                    const tag_name = session.resolveEnumTagNameOfNode(doc, value_node) orelse continue :case_values;

                    if (complete_tag_set.contains(tag_name))
                        try used_tag_set.put(tag_name, {});
                }
            }
        }

        if (else_case_node != null) {
            missing_tags.clearRetainingCapacity();

            for (enum_members) |member| {
                const tag = switch_expr_enum.tagName(session, member) orelse continue;
                if (!used_tag_set.contains(tag)) try missing_tags.append(session_arena, tag);
            }

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, tree.firstToken(node)),
                .end = .endOfToken(tree, tree.firstToken(node)),
                .message = buildProblemMessage(missing_tags.items, session_arena) catch "Error building linter message",
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            try lint_problems.toOwnedSlice(session_arena),
        )
    else
        null;
}

fn buildProblemMessage(missing: []const []const u8, gpa: std.mem.Allocator) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    try aw.writer.writeAll("Enum switch over exhaustive enum must list every tag explicitly; else is not allowed");

    if (missing.len > 0) {
        try aw.writer.writeAll(" (missing: ");
        for (missing, 0..) |tag, i| {
            if (i != 0) try aw.writer.writeAll(", ");
            try aw.writer.print(".{s}", .{tag});
        }
        try aw.writer.writeAll(")");
    }

    return try aw.toOwnedSlice();
}

test {
    std.testing.refAllDecls(@This());
}

test "require_exhaustive_enum_switch" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum {
        \\    idle,
        \\    running,
        \\    stopped,
        \\};
        \\
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running, .stopped => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_exhaustive_enum_switch",
                .severity = .warning,
                .slice = "switch",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .stopped)",
            },
        },
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_exhaustive_enum_switch",
                .severity = .warning,
                .slice = "switch",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .running, .stopped)",
            },
        },
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const Number = enum(u8) { one, two, three, _ };
        \\pub fn handle(number: Number) void {
        \\    switch (number) {
        \\        .one => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const Ok = enum { a, b, c, d };
        \\const b = Ok.a;
        \\const Other = Ok;
        \\
        \\pub fn references(value: Ok) void {
        \\    switch (value) {
        \\        b => {},
        \\        Other.b => {},
        \\        .c => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_exhaustive_enum_switch",
                .severity = .warning,
                .slice = "switch",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .d)",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
