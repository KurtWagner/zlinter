//! Enforces that variable declaration names use consistent naming. For example,
//! `snake_case` for non-types, `TitleCase` for types and `camelCase` for functions.

/// Config for declaration_naming rule.
pub const Config = struct {
    /// Exclude extern / foreign declarations. An extern declaration refers to a
    /// foreign declaration — typically defined outside of Zig, such as in a C
    /// library or other system-provided binary. You typically don't want to
    /// enforce naming conventions on these declarations.
    exclude_extern: bool = true,

    /// Exclude exported declarations. Export makes the symbol visible to
    /// external code, such as C or other languages that might link against
    /// your Zig code. You may prefer to rely on the naming conventions of
    /// the code being linked, in which case, you may set this to true.
    exclude_export: bool = false,

    /// When true the linter will exclude naming checks for declarations that have
    /// the same name as the field they're aliasing (e.g., `pub const FAILURE = system.FAILURE`).
    /// In these cases it can often be better to be consistent and to leave the
    /// naming convention up to the definition being aliased.
    exclude_aliases: bool = true,

    /// Style and severity for declarations with `var` mutability.
    var_decl: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Style and severity for declarations with `const` mutability.
    const_decl: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Style and severity for type declarations.
    decl_that_is_type: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Style and severity for namespace declarations.
    decl_that_is_namespace: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Style and severity for non-type function declarations.
    decl_that_is_fn: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .camel_case },

    /// Style and severity type function declarations.
    decl_that_is_type_fn: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Minimum length of a declarations name. To exclude names from this check
    /// see `decl_name_exclude_len` option. Set to `.off` to disable this
    /// check.
    decl_name_min_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 3 } },

    /// Maximum length of an `error` field name. To exclude names from this check
    /// see `decl_name_exclude_len` option. Set to `.off` to disable this
    /// check.
    decl_name_max_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 30 } },

    /// Exclude these declaration names from min and max declaration name checks.
    decl_name_exclude_len: []const []const u8 = zlinter.strings.default_excluded_short_names,
};

/// Builds and returns the declaration_naming rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.declaration_naming),
        .run = &run,
    };
}

/// Runs the declaration_naming rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    var index: u32 = 1; // Skip root node at 0
    nodes: while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const var_decl = tree.fullVarDecl(node) orelse continue :nodes;

        // Check whether name should be excluded from checks:
        if (config.exclude_extern and var_decl.extern_export_token != null) {
            const token_tag = tree.tokens.items(.tag)[var_decl.extern_export_token.?];
            if (token_tag == .keyword_extern) continue :nodes;
        }

        if (config.exclude_export and var_decl.extern_export_token != null) {
            const token_tag = tree.tokens.items(.tag)[var_decl.extern_export_token.?];
            if (token_tag == .keyword_export) continue :nodes;
        }

        const decl_id = session.decl_store.declIdByNode(
            doc.file_id,
            node,
        ) orelse continue :nodes;
        const name_token = var_decl.ast.mut_token + 1;
        const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(name_token));

        const init_is_this_builtin = if (var_decl.ast.init_node.unwrap()) |init_node|
            isThisBuiltinCall(tree, init_node)
        else
            false;

        var resolved_summaries: std.ArrayList(ResolvedSummary) = .empty;
        const summary_candidates = try session.resolveDeclValueSummaryCandidates(decl_id);
        for (summary_candidates) |candidate| {
            const resolved_summary: ResolvedSummary = .{
                .summary = candidate.summary,
                .source_decl_id = try resolvedSummarySourceDeclId(
                    session,
                    doc,
                    var_decl,
                    decl_id,
                    candidate.module_id,
                ),
            };
            try resolved_summaries.append(rule_arena, resolved_summary);
        }
        if (resolved_summaries.items.len == 0) {
            try resolved_summaries.append(rule_arena, .{ .summary = .other });
        }
        if (init_is_this_builtin) {
            // TODO: Move @This() value classification into the declaration type resolver.
            resolved_summaries.clearRetainingCapacity();
            try resolved_summaries.append(rule_arena, .{ .summary = .{ .type = .unknown } });
        }

        if (config.exclude_aliases) {
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (tree.nodeTag(init_node) == .field_access) {
                    const last_token = tree.lastToken(init_node);
                    const field_name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(last_token));
                    if (std.mem.eql(u8, field_name, name)) continue :nodes;
                }
            }
        }

        // Check name length:
        var emitted_len_diagnostic = false;
        if (config.decl_name_min_len.len()) |min_len| {
            if (name.len < min_len) {
                for (config.decl_name_exclude_len) |exclude_name| {
                    if (std.mem.eql(u8, name, exclude_name)) continue :nodes;
                }

                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = config.decl_name_min_len.severity(),
                    .start = .startOfToken(tree, name_token),
                    .end = .endOfToken(tree, name_token),
                    .message = try std.fmt.allocPrint(session_arena, "Declaration names should have a length greater or equal to {d}", .{min_len}),
                });
                emitted_len_diagnostic = true;
            }
        }
        if (!emitted_len_diagnostic) if (config.decl_name_max_len.len()) |max_len| {
            if (name.len > max_len) {
                for (config.decl_name_exclude_len) |exclude_name| {
                    if (std.mem.eql(u8, name, exclude_name)) continue :nodes;
                }

                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = config.decl_name_max_len.severity(),
                    .start = .startOfToken(tree, name_token),
                    .end = .endOfToken(tree, name_token),
                    .message = try std.fmt.allocPrint(session_arena, "Declaration names should have a length less or equal to {d}", .{max_len}),
                });
            }
        };

        // Check name style:
        for (resolved_summaries.items) |resolved_summary| {
            const style_diagnostic = styleDiagnostic(
                resolved_summary,
                tree.tokens.items(.tag)[var_decl.ast.mut_token],
                config,
            );
            const style = style_diagnostic.style_with_severity.style() orelse continue;
            if (style.check(name)) continue;

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = style_diagnostic.style_with_severity.severity(),
                .start = .startOfToken(tree, name_token),
                .end = .endOfToken(tree, name_token),
                .message = try std.fmt.allocPrint(session_arena, "{s} declaration should be {s}", .{
                    style_diagnostic.var_desc,
                    style.name(),
                }),
                .notes = try allocResolvedDeclNotes(session_arena, session, style_diagnostic.source_decl_id),
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

const ResolvedSummary = struct {
    summary: zlinter.session.TypeStore.TypeSummary,
    source_decl_id: ?zlinter.session.DeclStore.DeclId = null,
};

const StyleDiagnostic = struct {
    style_with_severity: zlinter.rules.LintTextStyleWithSeverity,
    var_desc: []const u8,
    source_decl_id: ?zlinter.session.DeclStore.DeclId,
};

fn styleDiagnostic(
    resolved_summary: ResolvedSummary,
    mut_token_tag: std.zig.Token.Tag,
    config: Config,
) StyleDiagnostic {
    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const var_desc: []const u8 =
        switch (resolved_summary.summary) {
            .fn_returns_type => .{ config.decl_that_is_type_fn, "Type function" },
            .@"fn" => .{ config.decl_that_is_fn, "Function" },
            .type => |type_value| switch (type_value.kind) {
                .namespace => .{ config.decl_that_is_namespace, "Namespace" },
                .@"fn", .fn_returns_type => .{ config.decl_that_is_type, "Function type" },
                .@"struct" => .{ config.decl_that_is_type, "Struct" },
                .@"enum" => .{ config.decl_that_is_type, "Enum" },
                .@"union" => .{ config.decl_that_is_type, "Union" },
                .@"opaque" => .{ config.decl_that_is_type, "Opaque" },
                .error_set => .{ config.decl_that_is_type, "Error" },
                .unknown, .primitive => .{ config.decl_that_is_type, "Type" },
            },
            .unknown,
            .other,
            .primitive,
            .instance,
            .slice,
            .array,
            => switch (mut_token_tag) {
                .keyword_const => .{ config.const_decl, "Constant" },
                .keyword_var => .{ config.var_decl, "Variable" },
                else => unreachable,
            },
        };

    return .{
        .style_with_severity = style_with_severity,
        .var_desc = var_desc,
        .source_decl_id = resolved_summary.source_decl_id,
    };
}

fn allocResolvedDeclNotes(
    session_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    maybe_decl_id: ?zlinter.session.DeclStore.DeclId,
) !?[]zlinter.results.LintProblemNote {
    const decl_id = maybe_decl_id orelse return null;
    const decl_location = session.declLocation(decl_id) orelse return null;

    const notes = try session_arena.alloc(zlinter.results.LintProblemNote, 1);
    notes[0] = .{
        .abs_path = try session_arena.dupe(u8, decl_location.abs_path),
        .start = decl_location.start,
        .end = decl_location.end,
        .line = decl_location.line,
        .column = decl_location.column,
        .message = try session_arena.dupe(u8, "resolved declaration is here"),
    };
    return notes;
}

fn resolvedSummarySourceDeclId(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    var_decl: Ast.full.VarDecl,
    decl_id: zlinter.session.DeclStore.DeclId,
    module_id: zlinter.session.ModuleStore.ModuleId,
) !?zlinter.session.DeclStore.DeclId {
    const tree = doc.tree(session);
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const init_expr = zlinter.ast.unwrapNode(tree, init_node, .{
        .unwrap_optional_unwrap = false,
    });

    var call_buffer: [1]Ast.Node.Index = undefined;
    const source_node = if (tree.fullCall(&call_buffer, init_expr)) |call|
        call.ast.fn_expr
    else
        init_expr;

    const source_decl_id = session.resolveDeclOfNodeForModule(
        module_id,
        doc,
        source_node,
    ) orelse return null;
    const resolved_source_decl_id = session.resolveDeclAliasForModule(
        module_id,
        source_decl_id,
    );

    if (resolved_source_decl_id == decl_id) return null;

    // Very basic heuristic that if on same line and file than not the
    // same declaration and should be noted in the problems notes. e.g.,
    // to link to the declaration that makes something the type it is.
    if (!declLocationsDifferLineOrFile(
        session,
        decl_id,
        resolved_source_decl_id,
    )) return null;
    return resolved_source_decl_id;
}

fn declLocationsDifferLineOrFile(
    session: *zlinter.session.LintSession,
    lhs_decl_id: zlinter.session.DeclStore.DeclId,
    rhs_decl_id: zlinter.session.DeclStore.DeclId,
) bool {
    const lhs = session.declLocation(lhs_decl_id) orelse return true;
    const rhs = session.declLocation(rhs_decl_id) orelse return true;

    return lhs.line != rhs.line or !std.mem.eql(u8, lhs.abs_path, rhs.abs_path);
}

fn isThisBuiltinCall(tree: Ast, node: Ast.Node.Index) bool {
    const expr = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });

    return switch (tree.nodeTag(expr)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(expr)), "@This"),
        else => false,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "declaration_naming" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\pub const hit_points: f32 = 1;
        \\const HitPoints: f32 = 1;
        \\var hitPoints: f32 = 1;
        \\const Good = u32;
        \\const bad = u32;
        \\const BadNamespace = struct {};
        \\const good_namespace = struct {};
        \\
        \\const thisIsOk = *const fn () void{};
        \\const ThisIsOk: *const fn () type = TypeFunc;
        \\
        \\const this_not_ok = *const fn () void{};
        \\const thisNotOk: *const fn () type = TypeFunc;
        \\
        \\fn TypeFunc() type {
        \\   return u32;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "HitPoints",
                .message = "Constant declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "hitPoints",
                .message = "Variable declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "bad",
                .message = "Type declaration should be TitleCase",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "BadNamespace",
                .message = "Namespace declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "this_not_ok",
                .message = "Function declaration should be camelCase",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "thisNotOk",
                .message = "Type function declaration should be TitleCase",
            },
        },
    );
}

test "declaration_naming classifies declaration values, not annotated instance types" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const Thing = struct {
        \\    const Self = @This();
        \\    field: u32,
        \\};
        \\const Choice = enum { a, b };
        \\
        \\const BadInstance: Thing = .{ .field = 1 };
        \\var badInstance: Thing = .{ .field = 2 };
        \\const BadChoice: Choice = .a;
        \\var badChoice: Choice = .b;
        \\const BadType: type = Thing;
        \\const bad_type: type = Thing;
        \\
        \\fn TypeFunc() type {
        \\    return Thing;
        \\}
        \\const goodTypeFunc: *const fn () type = TypeFunc;
        \\
        \\fn run() void {
        \\    var output: Thing = .{ .field = 3 };
        \\    _ = output;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "BadInstance",
                .message = "Constant declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "badInstance",
                .message = "Variable declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "BadChoice",
                .message = "Constant declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "badChoice",
                .message = "Variable declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "bad_type",
                .message = "Type declaration should be TitleCase",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "goodTypeFunc",
                .message = "Type function declaration should be TitleCase",
            },
        },
    );
}

test "declaration_naming classifies @This aliases as types" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "const Thing = struct { const Self = @This(); field: u32, };",
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const Thing = struct {
        \\    const bad_self = @This();
        \\    const THIS_IS_NOT_OK = @This();
        \\    field: u32,
        \\};
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "bad_self",
                .message = "Type declaration should be TitleCase",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "THIS_IS_NOT_OK",
                .message = "Type declaration should be TitleCase",
            },
        },
    );
}

test "declaration_naming notes resolved declaration used for alias classification" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const TypeAlias = enum { a };
        \\const bad_name = TypeAlias;
    ,
        .{},
        Config{ .exclude_aliases = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "bad_name",
                .message = "Enum declaration should be TitleCase",
                .notes = &.{"resolved declaration is here"},
            },
        },
    );
}

test "declaration_naming does not note local primitive classification" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "const bad = u32;",
        .{},
        Config{},
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "bad",
                .message = "Type declaration should be TitleCase",
                .notes = &.{},
            },
        },
    );
}

test "export included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "export const NotGood: u32 = 10;",
        .{},
        Config{ .exclude_export = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "NotGood",
                .message = "Constant declaration should be snake_case",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "export const notGood: u32 = 10;",
        .{},
        Config{ .exclude_export = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "notGood",
                .message = "Constant declaration should be snake_case",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "export const no_good = u32;",
        .{},
        Config{ .exclude_export = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "no_good",
                .message = "Type declaration should be TitleCase",
            },
        },
    );
}

test "export excluded" {
    inline for (&.{
        "export const NotGood: u32 = 10;",
        "export const notGood: u32 = 10;",
        "export const no_good = u32;",
    }) |source| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .exclude_export = true },
            &.{},
        );
    }
}

test "extern included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "extern const NotGood: u32;",
        .{},
        Config{ .exclude_extern = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "NotGood",
                .message = "Constant declaration should be snake_case",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "extern const notGood: u32;",
        .{},
        Config{ .exclude_extern = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "notGood",
                .message = "Constant declaration should be snake_case",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "extern const no_good: type;",
        .{},
        Config{ .exclude_extern = false },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "no_good",
                .message = "Type declaration should be TitleCase",
            },
        },
    );
}

test "extern excluded" {
    inline for (&.{
        "extern const NotGood: u32;",
        "extern const notGood: u32;",
        "extern const no_good: type;",
    }) |source| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .exclude_extern = true },
            &.{},
        );
    }
}

test "name lengths" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const s = 1;
        \\ const b = 2;
        \\ const oo = 3;
        \\ const ooo = 4;
        \\ const bbbb = 5;
        \\ const ssss = 6;
    ,
        .{},
        Config{
            .decl_name_max_len = .{ .warning = .{ .len = 3 } },
            .decl_name_min_len = .{ .@"error" = .{ .len = 2 } },
            .decl_name_exclude_len = &.{ "s", "ssss" },
        },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .slice = "b",
                .message = "Declaration names should have a length greater or equal to 2",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .warning,
                .slice = "bbbb",
                .message = "Declaration names should have a length less or equal to 3",
            },
        },
    );

    // Checks are off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const b = 1;
        \\ const bbbb = 2;
    ,
        .{},
        Config{
            .decl_name_max_len = .off,
            .decl_name_min_len = .off,
        },
        &.{},
    );
}

test "declaration_naming style off still checks const declaration length" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "const BadName = 1;",
        .{},
        Config{
            .const_decl = .off,
            .decl_name_max_len = .{ .warning = .{ .len = 3 } },
        },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .warning,
                .slice = "BadName",
                .message = "Declaration names should have a length less or equal to 3",
            },
        },
    );
}

test "declaration_naming style off still checks type declaration length" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "const bad_type = u32;",
        .{},
        Config{
            .decl_that_is_type = .off,
            .decl_name_max_len = .{ .warning = .{ .len = 3 } },
        },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .warning,
                .slice = "bad_type",
                .message = "Declaration names should have a length less or equal to 3",
            },
        },
    );
}

test "declaration_naming style off still checks function declaration length" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "const BadFn = fn () void {};",
        .{},
        Config{
            .decl_that_is_fn = .off,
            .decl_name_max_len = .{ .warning = .{ .len = 3 } },
        },
        &.{
            .{
                .rule_id = "declaration_naming",
                .severity = .warning,
                .slice = "BadFn",
                .message = "Declaration names should have a length less or equal to 3",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
