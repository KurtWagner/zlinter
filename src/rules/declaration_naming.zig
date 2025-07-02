//! Enforces that variable names that aren't types use snake_case

/// Config for declaration_naming rule.
pub const Config = struct {
    /// Declarations with `const` mutability
    var_decl: zlinter.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Declarations with `var` mutability
    const_decl: zlinter.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Type declarations
    decl_that_is_type: zlinter.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Namespace declarations
    decl_that_is_namespace: zlinter.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Non-type function declarations
    decl_that_is_fn: zlinter.LintTextStyleWithSeverity = .{
        .style = .camel_case,
        .severity = .@"error",
    },

    /// Type function declarations
    decl_that_is_type_fn: zlinter.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },
};

/// Builds and returns the declaration_naming rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.declaration_naming),
        .run = &run,
    };
}

/// Runs the declaration_naming rule.
fn run(
    rule: zlinter.LintRule,
    _: zlinter.LintContext,
    doc: zlinter.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.LintOptions,
) error{OutOfMemory}!?zlinter.LintResult {
    const config = options.getConfig(Config);

    var lint_problems = std.ArrayListUnmanaged(zlinter.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    var node: zlinter.shims.NodeIndexShim = .init(1); // Skip root node at 0
    while (node.index < tree.nodes.len) : (node.index += 1) {
        if (tree.fullVarDecl(node.toNodeIndex())) |var_decl| {
            if (try doc.resolveTypeKind(.{ .var_decl = var_decl })) |type_kind| {
                const name_token = var_decl.ast.mut_token + 1;
                const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(name_token));

                const style_with_severity: zlinter.LintTextStyleWithSeverity, const var_desc: []const u8 =
                    switch (type_kind) {
                        .fn_returns_type => .{ config.decl_that_is_type_fn, "Type function" },
                        .@"fn" => .{ config.decl_that_is_fn, "Function" },
                        .namespace_type => .{ config.decl_that_is_namespace, "Namespace" },
                        .type => .{ config.decl_that_is_type, "Type" },
                        .fn_type, .fn_type_returns_type => .{ config.decl_that_is_type, "Function type" },
                        .struct_type => .{ config.decl_that_is_type, "Struct" },
                        .enum_type => .{ config.decl_that_is_type, "Enum" },
                        .union_type => .{ config.decl_that_is_type, "Union" },
                        .opaque_type => .{ config.decl_that_is_type, "Opaque" },
                        .error_type => .{ config.decl_that_is_type, "Error" },
                        else => switch (tree.tokens.items(.tag)[var_decl.ast.mut_token]) {
                            .keyword_const => .{ config.const_decl, "Constant" },
                            .keyword_var => .{ config.var_decl, "Variable" },
                            else => unreachable,
                        },
                    };

                if (!style_with_severity.style.check(name)) {
                    try lint_problems.append(allocator, .{
                        .rule_id = rule.rule_id,
                        .severity = style_with_severity.severity,
                        .start = .startOfToken(tree, name_token),
                        .end = .endOfToken(tree, name_token),
                        .message = try std.fmt.allocPrint(allocator, "{s} declaration should be {s}", .{ var_desc, style_with_severity.style.name() }),
                    });
                }
            }
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.LintResult.init(
            allocator,
            doc.path,
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

test "declaration_naming" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});

    var result = (try zlinter.testing.runRule(rule, zlinter.testing.paths.posix("path/to/file.zig"),
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
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(result.file_path, zlinter.testing.paths.posix("path/to/file.zig"));

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.LintProblem{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 32,
                    .line = 2,
                    .column = 6,
                },
                .end = .{
                    .offset = 57,
                    .line = 2,
                    .column = 14,
                },
                .message = "Constant declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 58,
                    .line = 3,
                    .column = 4,
                },
                .end = .{
                    .offset = 81,
                    .line = 3,
                    .column = 12,
                },
                .message = "Variable declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 100,
                    .line = 5,
                    .column = 6,
                },
                .end = .{
                    .offset = 116,
                    .line = 5,
                    .column = 8,
                },
                .message = "Type declaration should be TitleCase",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 117,
                    .line = 6,
                    .column = 6,
                },
                .end = .{
                    .offset = 148,
                    .line = 6,
                    .column = 17,
                },
                .message = "Namespace declaration should be snake_case",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 269,
                    .line = 12,
                    .column = 6,
                },
                .end = .{
                    .offset = 309,
                    .line = 12,
                    .column = 16,
                },
                .message = "Function declaration should be camelCase",
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 310,
                    .line = 13,
                    .column = 6,
                },
                .end = .{
                    .offset = 356,
                    .line = 13,
                    .column = 14,
                },
                .message = "Type function declaration should be TitleCase",
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
