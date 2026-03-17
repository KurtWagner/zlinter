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

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    // Holds all tags within an enum used in a switch statement
    var complete_tag_set: std.StringHashMap(void) = .init(gpa);
    defer complete_tag_set.deinit();

    // Tracks only the used enum tags within a switch statement
    var used_tag_set = std.StringHashMap(void).init(gpa);
    defer used_tag_set.deinit();

    var missing_tags: std.ArrayList([]const u8) = .empty;
    defer missing_tags.deinit(gpa);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const switch_info = tree.fullSwitch(node) orelse continue :nodes;

        const switch_expr_type = try context.resolveTypeOfNode(
            doc,
            switch_info.ast.condition,
        ) orelse continue :nodes;

        const resolved_switch_expr_type = switch_expr_type.resolveDeclLiteralResultType();
        if (!resolved_switch_expr_type.isEnumType()) continue :nodes;

        var switch_expr_enum = try zlinter.ast.getEnumInfoFromType(
            resolved_switch_expr_type,
            gpa,
        ) orelse continue :nodes;
        defer switch_expr_enum.deinit(gpa);

        if (switch_expr_enum.is_non_exhaustive) continue :nodes;
        if (switch_expr_enum.tags.len == 0) continue :nodes;

        defer complete_tag_set.clearRetainingCapacity();
        try complete_tag_set.ensureTotalCapacity(@intCast(switch_expr_enum.tags.len));
        for (switch_expr_enum.tags) |tag| {
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
                    const tag_name = caseValueTagName(
                        tree,
                        value_node,
                    ) orelse continue :case_values;

                    if (complete_tag_set.contains(tag_name))
                        try used_tag_set.put(tag_name, {});
                }
            }
        }

        if (else_case_node != null) {
            missing_tags.clearRetainingCapacity();

            for (switch_expr_enum.tags) |tag| {
                if (!used_tag_set.contains(tag)) {
                    try missing_tags.append(gpa, tag);
                }
            }

            try lint_problems.append(gpa, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, tree.firstToken(node)),
                .end = .endOfToken(tree, tree.firstToken(node)),
                .message = buildProblemMessage(missing_tags.items, gpa) catch "Error building linter message",
            });
        }
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

fn caseValueTagName(tree: Ast, node: Ast.Node.Index) ?[]const u8 {
    return switch (tree.nodeTag(node)) {
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => blk: {
            // TODO: This should really resolve the actual type not assume.
            const last_token = tree.lastToken(node);
            if (tree.tokenTag(last_token) != .identifier) break :blk null;
            break :blk tree.tokenSlice(last_token);
        },
        else => null,
    };
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
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
