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
    var_decl: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for declarations with `const` mutability.
    const_decl: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for type declarations.
    decl_that_is_type: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Style and severity for namespace declarations.
    decl_that_is_namespace: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for non-type function declarations.
    decl_that_is_fn: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .camel_case,
        .severity = .@"error",
    },

    /// Style and severity type function declarations.
    decl_that_is_type_fn: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Minimum length of a declarations name. To exclude names from this check
    /// see `decl_name_exclude_len` option. Set to `.off` to disable this
    /// check.
    decl_name_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of an `error` field name. To exclude names from this check
    /// see `decl_name_exclude_len` option. Set to `.off` to disable this
    /// check.
    decl_name_max_len: zlinter.rules.LenAndSeverity = .{
        .len = 30,
        .severity = .warning,
    },

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
        if (var_decl.ast.init_node.unwrap()) |init_node| {
            if (isThisBuiltinCall(tree, init_node)) continue :nodes;
        }

        const type_summary = session.resolveDeclValueSummary(decl_id) orelse .other;
        const name_token = var_decl.ast.mut_token + 1;
        const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(name_token));

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
        if (config.decl_name_min_len.severity != .off and name.len < config.decl_name_min_len.len) {
            for (config.decl_name_exclude_len) |exclude_name| {
                if (std.mem.eql(u8, name, exclude_name)) continue :nodes;
            }

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.decl_name_min_len.severity,
                .start = .startOfToken(tree, name_token),
                .end = .endOfToken(tree, name_token),
                .message = try std.fmt.allocPrint(session_arena, "Declaration names should have a length greater or equal to {d}", .{config.decl_name_min_len.len}),
            });
        } else if (config.decl_name_max_len.severity != .off and name.len > config.decl_name_max_len.len) {
            for (config.decl_name_exclude_len) |exclude_name| {
                if (std.mem.eql(u8, name, exclude_name)) continue :nodes;
            }

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = config.decl_name_max_len.severity,
                .start = .startOfToken(tree, name_token),
                .end = .endOfToken(tree, name_token),
                .message = try std.fmt.allocPrint(session_arena, "Declaration names should have a length less or equal to {d}", .{config.decl_name_max_len.len}),
            });
        }

        // Check name style:
        const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const var_desc: []const u8 =
            switch (type_summary) {
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
                => switch (tree.tokens.items(.tag)[var_decl.ast.mut_token]) {
                    .keyword_const => .{ config.const_decl, "Constant" },
                    .keyword_var => .{ config.var_decl, "Variable" },
                    else => unreachable,
                },
            };

        if (!style_with_severity.style.check(name)) {
            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = style_with_severity.severity,
                .start = .startOfToken(tree, name_token),
                .end = .endOfToken(tree, name_token),
                .message = try std.fmt.allocPrint(session_arena, "{s} declaration should be {s}", .{ var_desc, style_with_severity.style.name() }),
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
            .decl_name_max_len = .{
                .severity = .warning,
                .len = 3,
            },
            .decl_name_min_len = .{
                .severity = .@"error",
                .len = 2,
            },
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
            .decl_name_max_len = .{
                .severity = .off,
                .len = 3,
            },
            .decl_name_min_len = .{
                .severity = .off,
                .len = 2,
            },
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
