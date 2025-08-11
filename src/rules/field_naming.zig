//! Enforces a consistent naming convention for fields in containers. For
//! example, `struct`, `enum`, `union`, `opaque` and `error`.

/// Config for field_naming rule.
pub const Config = struct {
    /// Style and severity for errors defined within an `error { ... }` container
    error_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Minimum length of a `error` field name. To exclude names from this check
    /// see `error_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    error_field_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of a `error` field name. To exclude names from this check
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

    /// Minimum length of a `enum` field name. To exclude names from this check
    /// see `enum_field_exclude_len` option. Set to `.off` to disable this
    /// check.
    enum_field_min_len: zlinter.rules.LenAndSeverity = .{
        .len = 3,
        .severity = .warning,
    },

    /// Maximum length of a `enum` field name. To exclude names from this check
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

    // TODO: Add capability for rules to have Context and before all hooks
    // to precompute information (e.g., for this to become a set or some other
    // structure more appropriate for these checks).

    /// Exclude these `struct` field names from min and max `struct` field name checks.
    struct_field_exclude_len: []const []const u8 = &.{
        // Rationale: x-coordinate
        "x",
        // Rationale: y-coordinate
        "y",
        // Rationale: z-coordinate
        "z",
        // Rationale: `i` for index
        "i",
        // Rationale: `b` for `std.Build`
        "b",
    },

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
    union_field_exclude_len: []const []const u8 = &.{
        // Rationale: x-coordinate
        "x",
        // Rationale: y-coordinate
        "y",
        // Rationale: z-coordinate
        "z",
        // Rationale: `i` for index
        "i",
        // Rationale: `b` for `std.Build`
        "b",
    },
};

/// Builds and returns the field_naming rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.field_naming),
        .run = &run,
    };
}

/// Runs the field_naming rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).init(allocator);
    defer lint_problems.deinit();

    const tree = doc.handle.tree;
    var buffer: [2]Ast.Node.Index = undefined;

    var node: NodeIndexShim = .root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
        const tag = shims.nodeTag(tree, node.toNodeIndex());
        if (tag == .error_set_decl) {
            const node_data = shims.nodeData(tree, node.toNodeIndex());

            const rbrace = switch (zlinter.version.zig) {
                .@"0.14" => node_data.rhs,
                .@"0.15" => node_data.token_and_token.@"1",
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

                            try lint_problems.append(.{
                                .rule_id = rule.rule_id,
                                .severity = min_len.severity,
                                .start = .startOfToken(tree, token),
                                .end = .endOfToken(tree, token),
                                .message = try std.fmt.allocPrint(allocator, "Error field names should have a length greater or equal to {d}", .{min_len.len}),
                            });
                        } else if (max_len.severity != .off and name_len > max_len.len) {
                            for (exclude_len) |exclude_name| {
                                if (std.mem.eql(u8, name, exclude_name)) continue :tokens;
                            }

                            try lint_problems.append(.{
                                .rule_id = rule.rule_id,
                                .severity = max_len.severity,
                                .start = .startOfToken(tree, token),
                                .end = .endOfToken(tree, token),
                                .message = try std.fmt.allocPrint(allocator, "Error field names should have a length less or equal to {d}", .{max_len.len}),
                            });
                        }

                        if (!config.error_field.style.check(name)) {
                            try lint_problems.append(.{
                                .rule_id = rule.rule_id,
                                .severity = config.error_field.severity,
                                .start = .startOfToken(tree, token),
                                .end = .endOfToken(tree, token),
                                .message = try std.fmt.allocPrint(allocator, "Error fields should be {s}", .{config.error_field.style.name()}),
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
                    const type_kind = try doc.resolveTypeKind(.{ .container_field = container_field });
                    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const container_kind: zlinter.session.LintDocument.TypeKind = tuple: {
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

                        try lint_problems.append(.{
                            .rule_id = rule.rule_id,
                            .severity = min_len.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(allocator, "{s} field names should have a length greater or equal to {d}", .{ container_kind.name(), min_len.len }),
                        });
                    } else if (max_len.severity != .off and name_len > max_len.len) {
                        for (exclude_len) |exclude_name| {
                            if (std.mem.eql(u8, name, exclude_name)) continue :fields;
                        }

                        try lint_problems.append(.{
                            .rule_id = rule.rule_id,
                            .severity = max_len.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(allocator, "{s} field names should have a length less or equal to {d}", .{ container_kind.name(), max_len.len }),
                        });
                    }

                    if (!style_with_severity.style.check(name)) {
                        try lint_problems.append(.{
                            .rule_id = rule.rule_id,
                            .severity = style_with_severity.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(allocator, "{s} fields should be {s}", .{ container_kind.name(), style_with_severity.style.name() }),
                        });
                    }
                }
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(),
        )
    else
        null;
}

fn handleNameLenCheck(
    rule: zlinter.rules.LintRule,
    tree: Ast,
    node: Ast.Node.Index,
    config: Config,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    allocator: std.mem.Allocator,
) !void {
    const min = config.struct_field_min_len;
    const max = config.struct_field_max_len;

    if (min.severity == .off and max.severity == .off) return;

    const container_field = tree.fullContainerField(node) orelse return;
    if (container_field.ast.tuple_like) return;

    const name_token = container_field.ast.main_token;
    const name_slice = tree.tokenSlice(name_token);
    const name_len = name_slice.len;

    if (min.severity != .off and name_len < min.len) {
        for (config.struct_field_exclude_len) |exclude_name| {
            if (std.mem.eql(u8, name_slice, exclude_name)) return;
        }

        try lint_problems.append(.{
            .rule_id = rule.rule_id,
            .severity = min.severity,
            .start = .startOfToken(tree, name_token),
            .end = .endOfToken(tree, name_token),
            .message = try std.fmt.allocPrint(allocator, "Field names should have a length greater or equal to {d}", .{min.len}),
        });
    } else if (max.severity != .off and name_len > max.len) {
        for (config.struct_field_exclude_len) |exclude_name| {
            if (std.mem.eql(u8, name_slice, exclude_name)) return;
        }

        try lint_problems.append(.{
            .rule_id = rule.rule_id,
            .severity = max.severity,
            .start = .startOfToken(tree, name_token),
            .end = .endOfToken(tree, name_token),
            .message = try std.fmt.allocPrint(allocator, "Field names should have a length less or equal to {d}", .{max.len}),
        });
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "regression 59 - tuples not included in field naming" {
    const rule = buildRule(.{});
    var result = try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
        "const Tuple = struct { TitleCase, snake_case, camelCase, MACRO_CASE };",
        .{},
    );
    defer if (result) |*r| r.deinit(std.testing.allocator);
    try std.testing.expectEqual(null, result);
}

test "run - implicit struct (root struct)" {
    const rule = buildRule(.{});
    const source =
        \\good: u32,
        \\also_good: u32,
        \\Notgood: u32,
        \\notGood: u32,
    ;
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
        source,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/file.zig"),
    );

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.results.LintProblem{
        .{
            .rule_id = "field_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 27,
                .line = 2,
                .column = 0,
            },
            .end = .{
                .byte_offset = 33,
                .line = 2,
                .column = 6,
            },
            .message = "Struct fields should be snake_case",
        },
        .{
            .rule_id = "field_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 41,
                .line = 3,
                .column = 0,
            },
            .end = .{
                .byte_offset = 47,
                .line = 3,
                .column = 6,
            },
            .message = "Struct fields should be snake_case",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("Notgood", result.problems[0].sliceSource(source));
    try std.testing.expectEqualStrings("notGood", result.problems[1].sliceSource(source));
}

test "run - union container" {
    const rule = buildRule(.{});
    const source =
        \\const A = union {
        \\ good: u32,
        \\ also_good: f32,
        \\ notGood: i32,
        \\ NotGood: i16
        \\};
    ;
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
        source,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.results.LintProblem{
        .{
            .rule_id = "field_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 48,
                .line = 3,
                .column = 1,
            },
            .end = .{
                .byte_offset = 54,
                .line = 3,
                .column = 7,
            },
            .message = "Union fields should be snake_case",
        },
        .{
            .rule_id = "field_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 63,
                .line = 4,
                .column = 1,
            },
            .end = .{
                .byte_offset = 69,
                .line = 4,
                .column = 7,
            },
            .message = "Union fields should be snake_case",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("notGood", result.problems[0].sliceSource(source));
    try std.testing.expectEqualStrings("NotGood", result.problems[1].sliceSource(source));
}

test "run - error container" {
    const rule = buildRule(.{});
    const source =
        \\const A = error {
        \\ Good,
        \\ AlsoGood,
        \\ not_good,
        \\ notGood
        \\};
    ;
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
        source,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.results.LintProblem{
        .{
            .rule_id = "field_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 48,
                .line = 4,
                .column = 1,
            },
            .end = .{
                .byte_offset = 54,
                .line = 4,
                .column = 7,
            },
            .message = "Error fields should be TitleCase",
        },
        .{
            .rule_id = "field_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 37,
                .line = 3,
                .column = 1,
            },
            .end = .{
                .byte_offset = 44,
                .line = 3,
                .column = 8,
            },
            .message = "Error fields should be TitleCase",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("notGood", result.problems[0].sliceSource(source));
    try std.testing.expectEqualStrings("not_good", result.problems[1].sliceSource(source));
}

test "name lengths" {
    // Struct fields are included:
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
                .slice =
                \\a
                ,
                .message = "Struct field names should have a length greater or equal to 2",
            },
            .{
                .rule_id = "field_naming",
                .severity = .warning,
                .slice =
                \\abcd
                ,
                .message = "Struct field names should have a length less or equal to 3",
            },
        },
    );

    // Tuples not included in length checks:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ const Struct = struct {
        \\  u32,
        \\  f32,
        \\  i32,
        \\  []const u8,
        \\};
    ,
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
