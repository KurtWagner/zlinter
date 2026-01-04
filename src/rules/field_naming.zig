//! Enforces a consistent naming convention for fields in containers. For
//! example, `struct`, `enum`, `union`, `opaque` and `error`.

/// Config for field_naming rule.
pub const Config = struct {
    /// Style and severity for errors defined within an `error { ... }` container
    error_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Minimum length of an `error` field name. To exclude names from this check
    /// see `error_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    error_field_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of an `error` field name. To exclude names from this check
    /// see `error_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    error_field_max_len: zlinter.rules.LenAndSeverity = .{
        .len = 30,
        .severity = .warning,
    },

    /// Exclude these `error` field names from min and max `error` field name checks.
    error_field_exclude_len: []const []const u8 = &.{},

    /// Style and severity for enum values defined within an `enum { ... }` container
    enum_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Minimum length of an `enum` field name. To exclude names from this check
    /// see `enum_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    enum_field_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of an `enum` field name. To exclude names from this check
    /// see `enum_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    enum_field_max_len: zlinter.rules.LenAndSeverity = .{
        .len = 30,
        .severity = .warning,
    },

    /// Exclude these `enum` field names from min and max `enum` field name checks.
    enum_field_exclude_len: []const []const u8 = &.{},

    /// Style and severity for struct fields defined within a `struct { ... }` container
    struct_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Minimum length of a `struct` field name. To exclude names from this check
    /// see `struct_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    struct_field_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of a `struct` field name. To exclude names from this check
    /// see `struct_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    struct_field_max_len: zlinter.rules.LenAndSeverity = .{
        .len = 30,
        .severity = .warning,
    },

    /// Exclude these `struct` field names from min and max `struct` field name checks.
    struct_field_exclude_len: []const []const u8 = zlinter.strings.default_excluded_short_names,

    /// Like `struct_field` but for fields with type `type`
    struct_field_that_is_type: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Like `struct_field` but for fields with a namespace type
    struct_field_that_is_namespace: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Like `struct_field` but for fields with a callable/function type
    struct_field_that_is_fn: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .camel_case,
        .severity = .@"error",
    },

    /// Like `struct_field_that_is_fn` but the callable/function returns a `type`
    struct_field_that_is_type_fn: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Style and severity for union fields defined within a `union { ... }` block
    union_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Minimum length of a `union` field name. To exclude names from this check
    /// see `union_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    union_field_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of a `union` field name. To exclude names from this check
    /// see `union_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    union_field_max_len: zlinter.rules.LenAndSeverity = .{
        .len = 30,
        .severity = .warning,
    },

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
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems: shims.ArrayList(zlinter.results.LintProblem) = .empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;
    var buffer: [2]Ast.Node.Index = undefined;

    var node: NodeIndexShim = .root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
        const tag = shims.nodeTag(tree, node.toNodeIndex());
        if (tag == .error_set_decl) {
            const node_data = shims.nodeData(tree, node.toNodeIndex());

            const rbrace = switch (zlinter.version.zig) {
                .@"0.14" => node_data.rhs,
                .@"0.15", .@"0.16" => node_data.token_and_token.@"1",
            };

            var token = rbrace - 1;
            tokens: while (token >= tree.firstToken(node.toNodeIndex())) : (token -= 1) {
                switch (tree.tokens.items(.tag)[token]) {
                    .identifier => {
                        const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(token));
                        const name_len = name.len;

                        const min_len = config.error_field_min_len;
                        const max_len = config.error_field_max_len;
                        const exclude_len = config.error_field_exclude_len;

                        if (min_len.severity != .off and name_len < min_len.len) {
                            for (exclude_len) |exclude_name| {
                                if (std.mem.eql(u8, name, exclude_name)) continue :tokens;
                            }

                            try lint_problems.append(gpa, .{
                                .rule_id = rule.rule_id,
                                .severity = min_len.severity,
                                .start = .startOfToken(tree, token),
                                .end = .endOfToken(tree, token),
                                .message = try std.fmt.allocPrint(gpa, "Error field names should have a length greater or equal to {d}", .{min_len.len}),
                            });
                        } else if (max_len.severity != .off and name_len > max_len.len) {
                            for (exclude_len) |exclude_name| {
                                if (std.mem.eql(u8, name, exclude_name)) continue :tokens;
                            }

                            try lint_problems.append(gpa, .{
                                .rule_id = rule.rule_id,
                                .severity = max_len.severity,
                                .start = .startOfToken(tree, token),
                                .end = .endOfToken(tree, token),
                                .message = try std.fmt.allocPrint(gpa, "Error field names should have a length less or equal to {d}", .{max_len.len}),
                            });
                        }

                        if (!config.error_field.style.check(name)) {
                            try lint_problems.append(gpa, .{
                                .rule_id = rule.rule_id,
                                .severity = config.error_field.severity,
                                .start = .startOfToken(tree, token),
                                .end = .endOfToken(tree, token),
                                .message = try std.fmt.allocPrint(gpa, "Error fields should be {s}", .{config.error_field.style.name()}),
                            });
                        }
                    },
                    else => {},
                }
            }
        } else if (tree.fullContainerDecl(&buffer, node.toNodeIndex())) |container_decl| {
            const container_tag = if (node.index == 0) .keyword_struct else tree.tokens.items(.tag)[container_decl.ast.main_token];

            fields: for (container_decl.ast.members) |member| {
                if (tree.fullContainerField(member)) |container_field| {
                    const type_kind = try context.resolveTypeKind(doc, .{ .container_field = container_field });
                    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const container_kind: zlinter.session.LintContext.TypeKind = tuple: {
                        break :tuple switch (container_tag) {
                            .keyword_struct => if (type_kind) |kind|
                                switch (kind) {
                                    .fn_returns_type => .{ config.struct_field_that_is_type_fn, kind },
                                    .@"fn" => .{ config.struct_field_that_is_fn, kind },
                                    .namespace_type => .{ config.struct_field_that_is_namespace, kind },
                                    .fn_type, .fn_type_returns_type => .{ config.struct_field_that_is_type, .fn_type },
                                    .type => .{ config.struct_field_that_is_type, kind },
                                    else => .{ config.struct_field, .struct_type },
                                }
                            else
                                .{ config.struct_field, .struct_type },
                            .keyword_union => .{ config.union_field, .union_type },
                            .keyword_enum => .{ config.enum_field, .enum_type },
                            else => continue :fields,
                        };
                    };

                    // Ignore struct tuples as they don't have names, just types
                    if (container_kind == .struct_type and container_field.ast.tuple_like) continue :fields;

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

                    if (min_len.severity != .off and name_len < min_len.len) {
                        for (exclude_len) |exclude_name| {
                            if (std.mem.eql(u8, name, exclude_name)) continue :fields;
                        }

                        try lint_problems.append(gpa, .{
                            .rule_id = rule.rule_id,
                            .severity = min_len.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(gpa, "{s} field names should have a length greater or equal to {d}", .{ container_kind.name(), min_len.len }),
                        });
                    } else if (max_len.severity != .off and name_len > max_len.len) {
                        for (exclude_len) |exclude_name| {
                            if (std.mem.eql(u8, name, exclude_name)) continue :fields;
                        }

                        try lint_problems.append(gpa, .{
                            .rule_id = rule.rule_id,
                            .severity = max_len.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(gpa, "{s} field names should have a length less or equal to {d}", .{ container_kind.name(), max_len.len }),
                        });
                    }

                    if (!style_with_severity.style.check(name)) {
                        try lint_problems.append(gpa, .{
                            .rule_id = rule.rule_id,
                            .severity = style_with_severity.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(gpa, "{s} fields should be {s}", .{ container_kind.name(), style_with_severity.style.name() }),
                        });
                    }
                }
            }
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
            .struct_field_max_len = .{
                .severity = .warning,
                .len = 3,
            },
            .struct_field_min_len = .{
                .severity = .@"error",
                .len = 2,
            },
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
            .struct_field_max_len = .{
                .severity = .warning,
                .len = 3,
            },
            .struct_field_min_len = .{
                .severity = .@"error",
                .len = 2,
            },
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
            .union_field_max_len = .{
                .severity = .warning,
                .len = 3,
            },
            .union_field_min_len = .{
                .severity = .@"error",
                .len = 2,
            },
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
            .enum_field_max_len = .{
                .severity = .warning,
                .len = 3,
            },
            .enum_field_min_len = .{
                .severity = .@"error",
                .len = 2,
            },
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
        Config{ .error_field_max_len = .{
            .severity = .warning,
            .len = 3,
        }, .error_field_min_len = .{
            .severity = .@"error",
            .len = 2,
        }, .error_field_exclude_len = &.{ "Z", "ZZZZ" } },
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

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
