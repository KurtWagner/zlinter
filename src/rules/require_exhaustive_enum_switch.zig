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
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    // Holds all tags within an enum used in a switch statement.
    var complete_tags = std.ArrayList([]const u8).empty;

    // Tracks only the used enum tags within a switch statement
    var used_tag_set = std.StringHashMap(void).init(rule_arena);

    var missing_tags: std.ArrayList([]const u8) = .empty;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const switch_info = tree.fullSwitch(node) orelse continue :nodes;

        defer complete_tags.clearRetainingCapacity();
        var enum_candidates = try session.resolveEnumCandidatesOfNode(
            rule_arena,
            doc,
            switch_info.ast.condition,
        );
        defer enum_candidates.deinit(rule_arena);
        for (enum_candidates.items) |candidate| {
            const switch_expr_enum = session.enumInfo(candidate.decl_id) orelse continue;
            if (switch_expr_enum.is_non_exhaustive) continue;

            var enum_member_buffer: [2]Ast.Node.Index = undefined;
            const enum_container_decl = switch_expr_enum.containerDecl(session, &enum_member_buffer) orelse
                continue;
            for (enum_container_decl.ast.members) |member| {
                const tag = switch_expr_enum.tagName(session, member) orelse continue;
                if (!containsString(complete_tags.items, tag)) try complete_tags.append(rule_arena, tag);
            }
        }
        if (complete_tags.items.len == 0) continue :nodes;

        // Set if an else case exists in switch
        var else_case_node: ?Ast.Node.Index = null;

        defer used_tag_set.clearRetainingCapacity();
        for (switch_info.ast.cases) |case_node| {
            const switch_case = tree.fullSwitchCase(case_node).?;

            if (switch_case.ast.values.len == 0) {
                if (else_case_node == null) else_case_node = case_node;
            } else {
                case_values: for (switch_case.ast.values) |value_node| {
                    var tag_candidates = try session.resolveEnumTagNameCandidatesOfNode(
                        rule_arena,
                        doc,
                        value_node,
                    );
                    defer tag_candidates.deinit(rule_arena);

                    for (tag_candidates.items) |tag_name| {
                        if (containsString(complete_tags.items, tag_name)) {
                            try used_tag_set.put(tag_name, {});
                            continue :case_values;
                        }
                    }
                }
            }
        }

        if (else_case_node) |case_node| {
            missing_tags.clearRetainingCapacity();

            for (complete_tags.items) |tag| {
                if (!used_tag_set.contains(tag)) try missing_tags.append(
                    rule_arena,
                    tag,
                );
            }

            const else_token = elseCaseToken(tree, case_node);
            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, else_token),
                .end = .endOfToken(tree, else_token),
                .message = buildProblemMessage(
                    missing_tags.items,
                    session_arena,
                ) catch "Error building linter message",
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

/// Returns the `else` keyword token for an else switch case.
/// For `inline else => |tag| tag`, this returns the `else` token, not `inline`.
fn elseCaseToken(tree: Ast, case_node: Ast.Node.Index) Ast.TokenIndex {
    const switch_case = tree.fullSwitchCase(case_node) orelse return tree.firstToken(case_node);
    const token_before_arrow = switch_case.ast.arrow_token - 1;
    if (tree.tokenTag(token_before_arrow) == .keyword_else) return token_before_arrow;
    return tree.firstToken(case_node);
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

fn containsString(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
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
                .slice = "else",
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
                .slice = "else",
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
                .slice = "else",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .d)",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
