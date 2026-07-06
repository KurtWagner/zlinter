//! Enforces a consistent naming convention for fields in containers. For
//! example, `struct`, `enum`, `union`, `opaque` and `error`.

/// Config for field_naming rule.
pub const Config = struct {
    /// Style and severity for errors defined within an `error { ... }` container
    error_field: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Minimum length of an `error` field name. To exclude names from this check
    /// see `error_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    error_field_min_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 3 } },

    /// Maximum length of an `error` field name. To exclude names from this check
    /// see `error_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    error_field_max_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 30 } },

    /// Exclude these `error` field names from min and max `error` field name checks.
    error_field_exclude_len: []const []const u8 = &.{},

    /// Style and severity for enum values defined within an `enum { ... }` container
    enum_field: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Minimum length of an `enum` field name. To exclude names from this check
    /// see `enum_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    enum_field_min_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 3 } },

    /// Maximum length of an `enum` field name. To exclude names from this check
    /// see `enum_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    enum_field_max_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 30 } },

    /// Exclude these `enum` field names from min and max `enum` field name checks.
    enum_field_exclude_len: []const []const u8 = &.{},

    /// Style and severity for struct fields defined within a `struct { ... }` container
    struct_field: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Minimum length of a `struct` field name. To exclude names from this check
    /// see `struct_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    struct_field_min_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 3 } },

    /// Maximum length of a `struct` field name. To exclude names from this check
    /// see `struct_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    struct_field_max_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 30 } },

    /// Exclude these `struct` field names from min and max `struct` field name checks.
    struct_field_exclude_len: []const []const u8 = zlinter.strings.default_excluded_short_names,

    /// Like `struct_field` but for fields with type `type`
    struct_field_that_is_type: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Like `struct_field` but for fields with a namespace type
    struct_field_that_is_namespace: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Like `struct_field` but for fields with a callable/function type
    struct_field_that_is_fn: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .camel_case },

    /// Like `struct_field_that_is_fn` but the callable/function returns a `type`
    struct_field_that_is_type_fn: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Style and severity for union fields defined within a `union { ... }` block
    union_field: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Minimum length of a `union` field name. To exclude names from this check
    /// see `union_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    union_field_min_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 3 } },

    /// Maximum length of a `union` field name. To exclude names from this check
    /// see `union_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    union_field_max_len: zlinter.rules.LenAndSeverity = .{ .warning = .{ .len = 30 } },

    /// Exclude these `union` field names from min and max `union` field name checks.
    union_field_exclude_len: []const []const u8 = zlinter.strings.default_excluded_short_names,
};

/// Builds and returns the field_naming rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.field_naming),
        .run = &run,
    };
}

/// Runs the field_naming rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const zone = zlinter.tracy.traceNamed(@src(), "rule.field_naming");
    defer zone.end();
    zone.addText(doc.absPath(session));

    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    const tree = doc.tree(session);
    var buffer: [2]Ast.Node.Index = undefined;

    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const tag = tree.nodeTag(node);
        if (tag == .error_set_decl) {
            const node_data = tree.nodeData(node);
            const lbrace = node_data.token_and_token.@"0";
            const rbrace = node_data.token_and_token.@"1";

            var token = rbrace;
            while (token > lbrace) {
                token -= 1;
                switch (tree.tokens.items(.tag)[token]) {
                    .identifier => {
                        const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(token));
                        const name_len = name.len;

                        const min_len = config.error_field_min_len;
                        const max_len = config.error_field_max_len;
                        const exclude_len = config.error_field_exclude_len;
                        var is_len_excluded = false;
                        for (exclude_len) |exclude_name|
                            if (std.mem.eql(u8, name, exclude_name)) {
                                is_len_excluded = true;
                                break;
                            };

                        if (!is_len_excluded) {
                            var emitted_len_diagnostic = false;
                            if (min_len.len()) |len| {
                                if (name_len < len) {
                                    try lint_problems.append(session_arena, .{
                                        .rule_id = rule.rule_id,
                                        .severity = min_len.severity(),
                                        .start = .startOfToken(tree, token),
                                        .end = .endOfToken(tree, token),
                                        .message = try session_arena.print("Error field names should have a length greater or equal to {d}", .{len}),
                                    });
                                    emitted_len_diagnostic = true;
                                }
                            }
                            if (!emitted_len_diagnostic) if (max_len.len()) |len| {
                                if (name_len > len) {
                                    try lint_problems.append(session_arena, .{
                                        .rule_id = rule.rule_id,
                                        .severity = max_len.severity(),
                                        .start = .startOfToken(tree, token),
                                        .end = .endOfToken(tree, token),
                                        .message = try session_arena.print("Error field names should have a length less or equal to {d}", .{len}),
                                    });
                                }
                            };
                        }

                        if (config.error_field.style()) |style| {
                            if (!style.check(name)) {
                                try lint_problems.append(session_arena, .{
                                    .rule_id = rule.rule_id,
                                    .severity = config.error_field.severity(),
                                    .start = .startOfToken(tree, token),
                                    .end = .endOfToken(tree, token),
                                    .message = try session_arena.print("Error fields should be {s}", .{style.name()}),
                                });
                            }
                        }
                    },
                    else => {},
                }
            }
        } else if (tree.fullContainerDecl(&buffer, node)) |container_decl| {
            const container_tag = if (node == .root) .keyword_struct else tree.tokens.items(.tag)[container_decl.ast.main_token];

            fields: for (container_decl.ast.members) |member|
                if (tree.fullContainerField(member)) |container_field| {
                    const type_summary = if (session.decl_store.declIdByNode(doc.file_id, member)) |decl_id| summary: {
                        const summary_candidates = try session.resolveDeclValueSummaryCandidates(decl_id);
                        for (summary_candidates) |candidate|
                            break :summary candidate.summary;
                        break :summary null;
                    } else null;
                    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const field_desc: []const u8 = tuple: {
                        break :tuple switch (container_tag) {
                            .keyword_struct => if (type_summary) |summary|
                                switch (summary) {
                                    .fn_returns_type => .{ config.struct_field_that_is_type_fn, "Type function" },
                                    .@"fn" => .{ config.struct_field_that_is_fn, "Function" },
                                    .type => |type_value| switch (type_value.kind) {
                                        .namespace => .{ config.struct_field_that_is_namespace, "Namespace" },
                                        .@"fn" => .{ config.struct_field_that_is_fn, "Function" },
                                        .fn_returns_type => .{ config.struct_field_that_is_type_fn, "Type function" },
                                        else => .{ config.struct_field_that_is_type, "Type" },
                                    },
                                    else => .{ config.struct_field, "Struct" },
                                }
                            else
                                .{ config.struct_field, "Struct" },
                            .keyword_union => .{ config.union_field, "Union" },
                            .keyword_enum => .{ config.enum_field, "Enum" },
                            else => continue :fields,
                        };
                    };

                    // Ignore struct tuples as they don't have names, just types
                    if (container_tag == .keyword_struct and container_field.ast.tuple_like) continue :fields;

                    const name_token = container_field.ast.main_token;
                    const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(name_token));
                    const name_len = name.len;

                    const min_len, const max_len, const exclude_len = switch (container_tag) {
                        .keyword_struct => .{ config.struct_field_min_len, config.struct_field_max_len, config.struct_field_exclude_len },
                        .keyword_enum => .{ config.enum_field_min_len, config.enum_field_max_len, config.enum_field_exclude_len },
                        .keyword_union => .{ config.union_field_min_len, config.union_field_max_len, config.union_field_exclude_len },
                        // Already skipped in previous switch. We could combine but
                        // the tuple may become way too noisy and less cohesive
                        else => unreachable,
                    };
                    var is_len_excluded = false;
                    // Underscore has special meaning in containers so lets
                    // completely skip for length checks.
                    if (std.mem.eql(u8, name, "_")) {
                        is_len_excluded = true;
                    } else for (exclude_len) |exclude_name|
                        if (std.mem.eql(u8, name, exclude_name)) {
                            is_len_excluded = true;
                            break;
                        };
                    const container_name: []const u8 = switch (container_tag) {
                        .keyword_struct => "Struct",
                        .keyword_enum => "Enum",
                        .keyword_union => "Union",
                        else => unreachable,
                    };

                    if (!is_len_excluded) {
                        var emitted_len_diagnostic = false;
                        if (min_len.len()) |len| {
                            if (name_len < len) {
                                try lint_problems.append(session_arena, .{
                                    .rule_id = rule.rule_id,
                                    .severity = min_len.severity(),
                                    .start = .startOfToken(tree, name_token),
                                    .end = .endOfToken(tree, name_token),
                                    .message = try session_arena.print("{s} field names should have a length greater or equal to {d}", .{ container_name, len }),
                                });
                                emitted_len_diagnostic = true;
                            }
                        }
                        if (!emitted_len_diagnostic) if (max_len.len()) |len| {
                            if (name_len > len) {
                                try lint_problems.append(session_arena, .{
                                    .rule_id = rule.rule_id,
                                    .severity = max_len.severity(),
                                    .start = .startOfToken(tree, name_token),
                                    .end = .endOfToken(tree, name_token),
                                    .message = try session_arena.print("{s} field names should have a length less or equal to {d}", .{ container_name, len }),
                                });
                            }
                        };
                    }

                    if (style_with_severity.style()) |style| {
                        if (!style.check(name)) {
                            try lint_problems.append(session_arena, .{
                                .rule_id = rule.rule_id,
                                .severity = style_with_severity.severity(),
                                .start = .startOfToken(tree, name_token),
                                .end = .endOfToken(tree, name_token),
                                .message = try session_arena.print("{s} fields should be {s}", .{ field_desc, style.name() }),
                            });
                        }
                    }
                };
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
}

test "regression 59 - tuples not included in field naming" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "const Tuple = struct { TitleCase, snake_case, camelCase, MACRO_CASE };",
        .{},
        Config{},
        &.{},
    );
}

test "run - implicit struct (root struct)" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\good: u32,
        \\also_good: u32,
        \\Notgood: u32,
        \\notGood: u32,
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "Notgood",
                .message = "Struct fields should be snake_case",
            },
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "notGood",
                .message = "Struct fields should be snake_case",
            },
        },
    );
}

test "run - struct fields classify values, not annotated concrete types" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const Token = enum(u32) { alpha };
        \\const namespace = struct { const value = 1; };
        \\const Struct = struct {
        \\    first: Token,
        \\    last: ?Token,
        \\    namespace_value: namespace,
        \\    TypeField: type,
        \\    bad_type: type,
        \\    FnField: *const fn () type,
        \\    bad_fn: *const fn () void,
        \\};
        \\
        \\const problem: ?struct { first: Token, last: Token } = null;
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "bad_type",
                .message = "Type fields should be TitleCase",
            },
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "bad_fn",
                .message = "Function fields should be camelCase",
            },
        },
    );
}

test "run - union container" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const A = union {
        \\ good: u32,
        \\ also_good: f32,
        \\ notGood: i32,
        \\ NotGood: i16
        \\};
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "notGood",
                .message = "Union fields should be snake_case",
            },
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "NotGood",
                .message = "Union fields should be snake_case",
            },
        },
    );
}

test "run - error container" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const A = error {
        \\ Good,
        \\ AlsoGood,
        \\ not_good,
        \\ notGood
        \\};
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "notGood",
                .message = "Error fields should be TitleCase",
            },
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "not_good",
                .message = "Error fields should be TitleCase",
            },
        },
    );
}

test "run - error container at start of file" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const E = error{A};
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice = "A",
                .message = "Error field names should have a length greater or equal to 3",
            },
        },
    );
}

test "run - empty error container at start of file" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const E = error{};
    ,
        .{},
        Config{},
        &.{},
    );
}

test "run - malformed error container at start of file" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\error{A}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice = "A",
                .message = "Error field names should have a length greater or equal to 3",
            },
        },
    );
}

test "run - style checks honor off severity" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const namespace = struct { const value = 1; };
        \\const bad_errors = error {
        \\    not_title_case,
        \\};
        \\const BadEnum = enum {
        \\    NotSnakeCase,
        \\};
        \\const BadUnion = union {
        \\    NotSnakeCase: u32,
        \\};
        \\const BadStruct = struct {
        \\    NotSnakeCase: u32,
        \\    bad_type: type,
        \\    NamespaceValue: namespace,
        \\    bad_fn: *const fn () void,
        \\    bad_type_fn: *const fn () type,
        \\};
    ,
        .{},
        Config{
            .error_field = .off,
            .enum_field = .off,
            .struct_field = .off,
            .struct_field_that_is_type = .off,
            .struct_field_that_is_namespace = .off,
            .struct_field_that_is_fn = .off,
            .struct_field_that_is_type_fn = .off,
            .union_field = .off,
            .error_field_min_len = .off,
            .error_field_max_len = .off,
            .enum_field_min_len = .off,
            .enum_field_max_len = .off,
            .struct_field_min_len = .off,
            .struct_field_max_len = .off,
            .union_field_min_len = .off,
            .union_field_max_len = .off,
        },
        &.{},
    );
}

test "name lengths" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Struct = struct {
        \\  s: u8,
        \\  ssss: u8,
        \\
        \\  a: u32,
        \\  ab: f32,
        \\  abc: i32,
        \\  abcd: []const u8,
        \\};
    ,
        .{},
        Config{
            .struct_field_max_len = .{ .warning = .{ .len = 3 } },
            .struct_field_min_len = .{ .@"error" = .{ .len = 2 } },
            .struct_field_exclude_len = &.{ "s", "ssss" },
        },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "a",
                .message = "Struct field names should have a length greater or equal to 2",
            },
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice = "abcd",
                .message = "Struct field names should have a length less or equal to 3",
            },
        },
    );

    // Tuples not included in length checks:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Tuple = struct {
        \\  u32,
        \\  f32,
        \\  i32,
        \\  []const u8,
        \\};
    ,
        .{},
        Config{
            .struct_field_max_len = .{ .warning = .{ .len = 3 } },
            .struct_field_min_len = .{ .@"error" = .{ .len = 2 } },
        },
        &.{},
    );

    // Union are included in length checks:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Union = union {
        \\  s: u8,
        \\  ssss: u8,
        \\
        \\  a: u32,
        \\  ab: f32,
        \\  abc: i32,
        \\  abcd: []const u8,
        \\};
    ,
        .{},
        Config{
            .union_field_max_len = .{ .warning = .{ .len = 3 } },
            .union_field_min_len = .{ .@"error" = .{ .len = 2 } },
            .union_field_exclude_len = &.{ "s", "ssss" },
        },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice =
                \\a
                ,
                .message = "Union field names should have a length greater or equal to 2",
            },
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice =
                \\abcd
                ,
                .message = "Union field names should have a length less or equal to 3",
            },
        },
    );

    // Union are included in length checks:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Enum = enum {
        \\  s,
        \\  ssss,
        \\
        \\  a,
        \\  ab,
        \\  abc,
        \\  abcd,
        \\};
    ,
        .{},
        Config{
            .enum_field_max_len = .{ .warning = .{ .len = 3 } },
            .enum_field_min_len = .{ .@"error" = .{ .len = 2 } },
            .enum_field_exclude_len = &.{ "s", "ssss" },
        },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice =
                \\a
                ,
                .message = "Enum field names should have a length greater or equal to 2",
            },
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice =
                \\abcd
                ,
                .message = "Enum field names should have a length less or equal to 3",
            },
        },
    );

    // Errors are included in length checks:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Errors = error {
        \\  Z,
        \\  ZZZZ,
        \\  A,
        \\  AB,
        \\  ABC,
        \\  ADBC,
        \\};
    ,
        .{},
        Config{ .error_field_max_len = .{ .warning = .{ .len = 3 } }, .error_field_min_len = .{ .@"error" = .{ .len = 2 } }, .error_field_exclude_len = &.{ "Z", "ZZZZ" } },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice =
                \\ADBC
                ,
                .message = "Error field names should have a length less or equal to 3",
            },
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice =
                \\A
                ,
                .message = "Error field names should have a length greater or equal to 2",
            },
        },
    );
}

test "length exclusions do not skip struct style checks" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Struct = struct {
        \\  BadName: u8,
        \\ };
    ,
        .{},
        Config{
            .struct_field_min_len = .{ .warning = .{ .len = 20 } },
            .struct_field_max_len = .{ .warning = .{ .len = 3 } },
            .struct_field_exclude_len = &.{"BadName"},
        },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "BadName",
                .message = "Struct fields should be snake_case",
            },
        },
    );
}

test "length exclusions do not skip error style checks" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Errors = error {
        \\  BadName,
        \\ };
    ,
        .{},
        Config{
            .error_field = .{ .@"error" = .snake_case },
            .error_field_min_len = .{ .warning = .{ .len = 20 } },
            .error_field_max_len = .{ .warning = .{ .len = 3 } },
            .error_field_exclude_len = &.{"BadName"},
        },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .@"error",
                .slice = "BadName",
                .message = "Error fields should be snake_case",
            },
        },
    );
}

test "length exclusions always ignores `_`" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Kind = enum {
        \\  a = 1,
        \\  b = 2,
        \\  _,
        \\ };
    ,
        .{},
        Config{
            .enum_field = .{ .@"error" = .snake_case },
            .enum_field_min_len = .{ .warning = .{ .len = 5 } },
            .enum_field_max_len = .{ .warning = .{ .len = 10 } },
            .enum_field_exclude_len = &.{"b"},
        },
        &.{
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice = "a",
                .message = "Enum field names should have a length greater or equal to 5",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
