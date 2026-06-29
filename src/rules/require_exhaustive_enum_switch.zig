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

    // Tracks only the used enum tags within a switch statement
    var used_tag_set = std.StringHashMap(void).init(rule_arena);

    var missing_tags: std.ArrayList([]const u8) = .empty;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const switch_info = tree.fullSwitch(node) orelse continue :nodes;

        const enum_candidates = try session.resolveEnumCandidatesOfNode(
            rule_arena,
            doc,
            switch_info.ast.condition,
        );
        const enum_tag_sets = try enumTagSets(
            session,
            rule_arena,
            enum_candidates,
        );
        if (enum_tag_sets.items.len == 0)
            continue :nodes;

        // Set if an else case exists in switch
        var else_case_node: ?Ast.Node.Index = null;

        for (enum_tag_sets.items) |enum_tag_set| {
            const complete_tags = enum_tag_set.tags;
            used_tag_set.clearRetainingCapacity();
            for (switch_info.ast.cases) |case_node| {
                const switch_case = tree.fullSwitchCase(case_node).?;

                if (switch_case.ast.values.len == 0) {
                    if (else_case_node == null) else_case_node = case_node;
                } else {
                    case_values: for (switch_case.ast.values) |value_node| {
                        const tag_candidates = try session.resolveEnumTagNameCandidatesOfNode(
                            rule_arena,
                            doc,
                            value_node,
                        );

                        for (tag_candidates) |tag_name| {
                            if (containsString(complete_tags, tag_name)) {
                                try used_tag_set.put(tag_name, {});
                                continue :case_values;
                            }
                        }
                    }
                }
            }

            if (else_case_node) |case_node| {
                missing_tags.clearRetainingCapacity();

                for (complete_tags) |tag| {
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
                    .notes = try allocEnumDeclNotes(session_arena, session, enum_tag_set.decl_id),
                    .message = buildProblemMessage(
                        missing_tags.items,
                        session_arena,
                    ) catch "Error building linter message",
                });
            }
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

fn buildProblemMessage(missing: []const []const u8, session_arena: std.mem.Allocator) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(session_arena);
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

const EnumTagSet = struct {
    decl_id: zlinter.session.DeclStore.DeclId,
    tags: []const []const u8,
};

fn enumTagSets(
    session: *zlinter.session.LintSession,
    allocator: std.mem.Allocator,
    candidates: []const zlinter.session.LintSession.EnumCandidate,
) !std.ArrayList(EnumTagSet) {
    var seen_decl_ids: std.AutoHashMap(
        zlinter.session.DeclStore.DeclId,
        void,
    ) = .init(allocator);

    var tag_sets: std.ArrayList(EnumTagSet) = .empty;

    for (candidates) |candidate| {
        const gop = try seen_decl_ids.getOrPut(candidate.decl_id);
        if (gop.found_existing) continue;

        const tags = try enumTags(
            session,
            allocator,
            candidate.decl_id,
        ) orelse
            continue;

        if (tags.len == 0) continue;

        try tag_sets.append(allocator, .{
            .decl_id = candidate.decl_id,
            .tags = tags,
        });
    }

    return tag_sets;
}

fn enumTags(
    session: *zlinter.session.LintSession,
    allocator: std.mem.Allocator,
    decl_id: zlinter.session.DeclStore.DeclId,
) !?[]const []const u8 {
    const switch_expr_enum = session.enumInfo(decl_id) orelse return null;
    if (switch_expr_enum.is_non_exhaustive) return null;

    var enum_member_buffer: [2]Ast.Node.Index = undefined;
    const enum_container_decl = switch_expr_enum.containerDecl(
        session,
        &enum_member_buffer,
    ) orelse
        return null;

    var tags: std.ArrayList([]const u8) = .empty;
    for (enum_container_decl.ast.members) |member| {
        const tag = switch_expr_enum.tagName(session, member) orelse
            continue;
        try tags.append(allocator, tag);
    }

    return try tags.toOwnedSlice(allocator);
}

fn allocEnumDeclNotes(
    session_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    decl_id: zlinter.session.DeclStore.DeclId,
) !?[]zlinter.results.LintProblemNote {
    const decl_location = session.declLocation(decl_id) orelse return null;

    const notes = try session_arena.alloc(zlinter.results.LintProblemNote, 1);
    notes[0] = .{
        .abs_path = try session_arena.dupe(u8, decl_location.abs_path),
        .start = decl_location.start,
        .end = decl_location.end,
        .line = decl_location.line,
        .column = decl_location.column,
        .message = try session_arena.dupe(u8, "enum declaration is here"),
    };
    return notes;
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

test "require_exhaustive_enum_switch allows explicit exhaustive cases" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
}

test "require_exhaustive_enum_switch reports else when one tag is missing" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
        &.{.{
            .rule_id = "require_exhaustive_enum_switch",
            .severity = .warning,
            .slice = "else",
            .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .stopped)",
        }},
    );
}

test "require_exhaustive_enum_switch allows missing explicit cases without else" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
}

test "require_exhaustive_enum_switch reports else when multiple tags are missing" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
        &.{.{
            .rule_id = "require_exhaustive_enum_switch",
            .severity = .warning,
            .slice = "else",
            .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .running, .stopped)",
        }},
    );
}

test "require_exhaustive_enum_switch ignores non-exhaustive enums" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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

test "require_exhaustive_enum_switch resolves referenced enum tags" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
        &.{.{
            .rule_id = "require_exhaustive_enum_switch",
            .severity = .warning,
            .slice = "else",
            .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .d)",
        }},
    );
}

test "require_exhaustive_enum_switch resolves enum aliases in switch conditions" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const State = enum { idle, running, stopped };
        \\const StateAlias = State;
        \\
        \\pub fn handle(state: StateAlias) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "require_exhaustive_enum_switch",
            .severity = .warning,
            .slice = "else",
            .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .stopped)",
        }},
    );
}

test "require_exhaustive_enum_switch reports inline else on exhaustive enums" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running => {},
        \\        inline else => |tag| _ = tag,
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{.{
            .rule_id = "require_exhaustive_enum_switch",
            .severity = .warning,
            .slice = "else",
            .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .stopped)",
        }},
    );
}

test "require_exhaustive_enum_switch severity off suppresses reports" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
