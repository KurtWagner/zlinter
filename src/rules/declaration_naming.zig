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

    /// Style and severity for declarations with `const` mutability.
    var_decl: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for declarations with `var` mutability.
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
};

/// Builds and returns the declaration_naming rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.declaration_naming),
        .run = &run,
    };
}

/// Runs the declaration_naming rule.
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

    var node: zlinter.shims.NodeIndexShim = .init(1); // Skip root node at 0
    skip: while (node.index < tree.nodes.len) : (node.index += 1) {
        const var_decl = tree.fullVarDecl(node.toNodeIndex()) orelse continue :skip;

        if (config.exclude_extern and var_decl.extern_export_token != null) {
            const token_tag = tree.tokens.items(.tag)[var_decl.extern_export_token.?];
            if (token_tag == .keyword_extern) continue :skip;
        }

        if (config.exclude_export and var_decl.extern_export_token != null) {
            const token_tag = tree.tokens.items(.tag)[var_decl.extern_export_token.?];
            if (token_tag == .keyword_export) continue :skip;
        }

        const type_kind = try doc.resolveTypeKind(.{ .var_decl = var_decl }) orelse continue :skip;
        const name_token = var_decl.ast.mut_token + 1;
        const name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(name_token));

        if (config.exclude_aliases) {
            if (zlinter.shims.NodeIndexShim.initOptional(var_decl.ast.init_node)) |init_node| {
                if (zlinter.shims.nodeTag(tree, init_node.toNodeIndex()) == .field_access) {
                    const last_token = tree.lastToken(init_node.toNodeIndex());
                    const field_name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(last_token));
                    if (std.mem.eql(u8, field_name, name)) continue :skip;
                }
            }
        }

        const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const var_desc: []const u8 =
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

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
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

    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
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
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(result.file_path, zlinter.testing.paths.posix("path/to/file.zig"));

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .byte_offset = 38,
                    .line = 2,
                    .column = 6,
                },
                .end = .{
                    .byte_offset = 46,
                    .line = 2,
                    .column = 14,
                },
                .message = "Constant declaration should be snake_case",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .byte_offset = 62,
                    .line = 3,
                    .column = 4,
                },
                .end = .{
                    .byte_offset = 70,
                    .line = 3,
                    .column = 12,
                },
                .message = "Variable declaration should be snake_case",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .byte_offset = 106,
                    .line = 5,
                    .column = 6,
                },
                .end = .{
                    .byte_offset = 108,
                    .line = 5,
                    .column = 8,
                },
                .message = "Type declaration should be TitleCase",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .byte_offset = 123,
                    .line = 6,
                    .column = 6,
                },
                .end = .{
                    .byte_offset = 134,
                    .line = 6,
                    .column = 17,
                },
                .message = "Namespace declaration should be snake_case",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .byte_offset = 275,
                    .line = 12,
                    .column = 6,
                },
                .end = .{
                    .byte_offset = 285,
                    .line = 12,
                    .column = 16,
                },
                .message = "Function declaration should be camelCase",
                .disabled_by_comment = false,
                .fix = null,
            },
            .{
                .rule_id = "declaration_naming",
                .severity = .@"error",
                .start = .{
                    .byte_offset = 316,
                    .line = 13,
                    .column = 6,
                },
                .end = .{
                    .byte_offset = 324,
                    .line = 13,
                    .column = 14,
                },
                .message = "Type function declaration should be TitleCase",
                .disabled_by_comment = false,
                .fix = null,
            },
        },
        result.problems,
    );
}

test "export included" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    inline for (&.{
        "export const NotGood: u32 = 10;",
        "export const notGood: u32 = 10;",
        "export const no_good = u32;",
    }) |source| {
        var config = Config{ .exclude_export = false };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/file.zig"),
            source,
            .{
                .config = &config,
            },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(1, result.?.problems.len);
    }
}

test "export excluded" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    inline for (&.{
        "export const NotGood: u32 = 10;",
        "export const notGood: u32 = 10;",
        "export const no_good = u32;",
    }) |source| {
        var config = Config{ .exclude_export = true };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/file.zig"),
            source,
            .{
                .config = &config,
            },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(null, result);
    }
}

test "extern included" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    inline for (&.{
        "extern const NotGood: u32;",
        "extern const notGood: u32;",
        "extern const no_good: type;",
    }) |source| {
        var config = Config{ .exclude_extern = false };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/file.zig"),
            source,
            .{
                .config = &config,
            },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(1, result.?.problems.len);
    }
}

test "extern excluded" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    inline for (&.{
        "extern const NotGood: u32;",
        "extern const notGood: u32;",
        "extern const no_good: type;",
    }) |source| {
        var config = Config{ .exclude_extern = true };
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/file.zig"),
            source,
            .{
                .config = &config,
            },
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(null, result);
    }
}

const std = @import("std");
const zlinter = @import("zlinter");
