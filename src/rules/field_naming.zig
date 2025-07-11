//! Enforces a consistent naming convention for fields in containers. For
//! example, `struct`, `enum`, `union`, `opaque` and `error`.

/// Config for field_naming rule.
pub const Config = struct {
    /// Style and severity for errors defined within an `error { ... }` container
    error_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Style and severity for enum values defined within an `enum { ... }` container
    enum_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for struct fields defined within a `struct { ... }` container
    struct_field: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
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

    var lint_problems = std.ArrayListUnmanaged(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;

    var node: zlinter.shims.NodeIndexShim = .root;
    while (node.index < tree.nodes.len) : (node.index += 1) {
        if (tree.fullContainerDecl(&buffer, node.toNodeIndex())) |container_decl| {
            const container_tag = if (node.index == 0) .keyword_struct else tree.tokens.items(.tag)[container_decl.ast.main_token];

            for (container_decl.ast.members) |member| {
                if (tree.fullContainerField(member)) |container_field| {
                    const type_kind = try doc.resolveTypeKind(.{ .container_field = container_field });
                    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const container_name: []const u8 = tuple: {
                        break :tuple switch (container_tag) {
                            .keyword_struct => if (type_kind) |kind|
                                switch (kind) {
                                    .fn_returns_type => .{ config.struct_field_that_is_type_fn, "Type function" },
                                    .@"fn" => .{ config.struct_field_that_is_fn, "Function" },
                                    .namespace_type => .{ config.struct_field_that_is_namespace, "Namespace" },
                                    .fn_type, .fn_type_returns_type => .{ config.struct_field_that_is_type, "Function Type" },
                                    .type => .{ config.struct_field_that_is_type, "Type" },
                                    else => .{ config.struct_field, "Struct" },
                                }
                            else
                                .{ config.struct_field, "Struct" },
                            .keyword_union => .{ config.union_field, "Union" },
                            .keyword_enum => .{ config.enum_field, "Enum" },
                            else => continue,
                        };
                    };

                    const name_token = container_field.ast.main_token;
                    const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(name_token));

                    if (!style_with_severity.style.check(name)) {
                        try lint_problems.append(allocator, .{
                            .rule_id = rule.rule_id,
                            .severity = style_with_severity.severity,
                            .start = .startOfToken(tree, name_token),
                            .end = .endOfToken(tree, name_token),
                            .message = try std.fmt.allocPrint(allocator, "{s} fields should be {s}", .{ container_name, style_with_severity.style.name() }),
                        });
                    }
                }
            }
        } else if (zlinter.shims.nodeTag(tree, node.toNodeIndex()) == .error_set_decl) {
            const node_data = zlinter.shims.nodeData(tree, node.toNodeIndex());

            const rbrace = switch (zlinter.version.zig) {
                .@"0.14" => node_data.rhs,
                .@"0.15" => node_data.token_and_token.@"1",
            };

            var token = rbrace - 1;
            while (token >= tree.firstToken(node.toNodeIndex())) : (token -= 1) {
                switch (tree.tokens.items(.tag)[token]) {
                    .identifier => if (!config.error_field.style.check(zlinter.strings.normalizeIdentifierName(tree.tokenSlice(token)))) {
                        try lint_problems.append(allocator, .{
                            .rule_id = rule.rule_id,
                            .severity = config.error_field.severity,
                            .start = .startOfToken(tree, token),
                            .end = .endOfToken(tree, token),
                            .message = try std.fmt.allocPrint(allocator, "Error fields should be {s}", .{config.error_field.style.name()}),
                        });
                    },
                    else => {},
                }
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

test {
    std.testing.refAllDecls(@This());
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

const std = @import("std");
const zlinter = @import("zlinter");
