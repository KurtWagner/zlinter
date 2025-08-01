//! Enforces consistent naming of functions. For example, `TitleCase` for functions
//! that return types and `camelCase` for others.

/// Config for function_naming rule.
pub const Config = struct {
    /// Exclude extern / foreign functions. An extern function refers to a
    /// foreign function — typically defined outside of Zig, such as in a C
    /// library or other system-provided binary. You typically don't want to
    /// enforce naming conventions on these functions.
    exclude_extern: bool = true,

    /// Exclude exported functions. Export makes the symbol visible to
    /// external code, such as C or other languages that might link against
    /// your Zig code. You may prefer to rely on the naming conventions of
    /// the code being linked, in which case, you may set this to true.
    exclude_export: bool = false,

    /// Style and severity for non-type functions
    function: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .camel_case,
        .severity = .@"error",
    },

    /// Style and severity for type functions
    function_that_returns_type: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Style and severity for standard function arg
    function_arg: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for type function arg
    function_arg_that_is_type: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },

    /// Style and severity for non-type function function arg
    function_arg_that_is_fn: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .camel_case,
        .severity = .@"error",
    },

    /// Style and severity for type function function arg
    function_arg_that_is_type_fn: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },
};

/// Builds and returns the function_naming rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.function_naming),
        .run = &run,
    };
}

/// Runs the function_naming rule.
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
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (namedFnProto(tree, &buffer, node.toNodeIndex())) |fn_proto| {
            if (config.exclude_extern and fn_proto.extern_export_inline_token != null) {
                const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
                if (token_tag == .keyword_extern) continue :skip;
            }
            if (config.exclude_export and fn_proto.extern_export_inline_token != null) {
                const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
                if (token_tag == .keyword_export) continue :skip;
            }

            const fn_name_token = fn_proto.name_token.?;
            const fn_name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(fn_name_token));

            const return_type = (try doc.resolveTypeOfTypeNode(
                switch (zlinter.version.zig) {
                    .@"0.14" => fn_proto.ast.return_type,
                    .@"0.15" => fn_proto.ast.return_type.unwrap().?,
                },
            )) orelse continue :skip;

            const error_message: ?[]const u8, const severity: ?zlinter.rules.LintProblemSeverity = msg: {
                if (return_type.isMetaType()) {
                    if (!config.function_that_returns_type.style.check(fn_name)) {
                        break :msg .{
                            try std.fmt.allocPrint(allocator, "Callable returning `type` should be {s}", .{config.function_that_returns_type.style.name()}),
                            config.function_that_returns_type.severity,
                        };
                    }
                } else {
                    if (!config.function.style.check(fn_name)) {
                        break :msg .{
                            try std.fmt.allocPrint(allocator, "Callable should be {s}", .{config.function.style.name()}),
                            config.function.severity,
                        };
                    }
                }
                break :msg .{ null, null };
            };

            if (error_message) |message| {
                try lint_problems.append(
                    allocator,
                    .{
                        .severity = severity.?,
                        .rule_id = rule.rule_id,
                        .start = .startOfToken(tree, fn_name_token),
                        .end = .endOfToken(tree, fn_name_token),
                        .message = message,
                    },
                );
            }
        }

        // Check arguments:
        if (fnProto(tree, &buffer, node.toNodeIndex())) |fn_proto| {
            if (config.exclude_extern and fn_proto.extern_export_inline_token != null) {
                const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
                if (token_tag == .keyword_extern) continue :skip;
            }
            if (config.exclude_export and fn_proto.extern_export_inline_token != null) {
                const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
                if (token_tag == .keyword_export) continue :skip;
            }

            for (fn_proto.ast.params) |param| {
                const colon_token = tree.firstToken(param) - 1;
                if (tree.tokens.items(.tag)[colon_token] != .colon) continue;

                const identifer_token = colon_token - 1;
                if (tree.tokens.items(.tag)[identifer_token] != .identifier) continue;
                const identifier = tree.tokenSlice(identifer_token);

                if (identifier.len == 1 and identifier[0] == '_') continue;

                if (try doc.resolveTypeOfTypeNode(param)) |param_type| {
                    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const desc: []const u8 =
                        if (param_type.isTypeFunc())
                            .{ config.function_arg_that_is_type_fn, "Function argument of type function" }
                        else if (param_type.isFunc())
                            .{ config.function_arg_that_is_fn, "Function argument of function" }
                        else if (param_type.isMetaType())
                            .{ config.function_arg_that_is_type, "Function argument of type" }
                        else
                            .{ config.function_arg, "Function argument" };

                    if (!style_with_severity.style.check(identifier)) {
                        try lint_problems.append(allocator, .{
                            .rule_id = rule.rule_id,
                            .severity = style_with_severity.severity,
                            .start = .startOfToken(tree, identifer_token),
                            .end = .endOfToken(tree, identifer_token),
                            .message = try std.fmt.allocPrint(allocator, "{s} should be {s}", .{ desc, style_with_severity.style.name() }),
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
            try lint_problems.toOwnedSlice(allocator),
        )
    else
        null;
}

/// Returns fn proto if node is fn proto and has a name token.
pub fn namedFnProto(tree: std.zig.Ast, buffer: *[1]std.zig.Ast.Node.Index, node: std.zig.Ast.Node.Index) ?std.zig.Ast.full.FnProto {
    if (fnProto(tree, buffer, node)) |fn_proto| {
        if (fn_proto.name_token != null) return fn_proto;
    }
    return null;
}

/// Returns fn proto if node is fn proto and has a name token.
pub fn fnProto(tree: std.zig.Ast, buffer: *[1]std.zig.Ast.Node.Index, node: std.zig.Ast.Node.Index) ?std.zig.Ast.full.FnProto {
    if (switch (zlinter.shims.nodeTag(tree, node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buffer, node),
        .fn_proto_simple => tree.fnProtoSimple(buffer, node),
        else => null,
    }) |fn_proto| {
        return fn_proto;
    }
    return null;
}

test "export excluded" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\export fn export_not_good() void;
        \\export fn exportNotGood() void;
        \\export fn exportWith(BadArg: u32) void;
    ;
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

test "export included" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\export fn export_not_good() void;
        \\export fn exportGood() void;
        \\export fn exportWith(BadArg: u32) void;
    ;
    var config = Config{ .exclude_export = false };
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
        source,
        .{
            .config = &config,
        },
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/file.zig"),
    );

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.results.LintProblem{
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 10,
                .line = 0,
                .column = 10,
            },
            .end = .{
                .byte_offset = 24,
                .line = 0,
                .column = 24,
            },
            .message = "Callable should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 84,
                .line = 2,
                .column = 21,
            },
            .end = .{
                .byte_offset = 89,
                .line = 2,
                .column = 26,
            },
            .message = "Function argument should be snake_case",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("export_not_good", result.problems[0].sliceSource(source));
}

test "extern excluded" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\extern fn extern_not_good() void;
        \\extern fn ExternNotGood() void;
        \\extern fn externWith(BadArg: u32) void;
    ;
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

test "extern included" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\extern fn extern_not_good() void;
        \\extern fn externGood() void;
        \\extern fn externWith(BadArg: u32) void;
    ;
    var config = Config{ .exclude_extern = false };
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/file.zig"),
        source,
        .{
            .config = &config,
        },
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/file.zig"),
    );

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.results.LintProblem{
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 10,
                .line = 0,
                .column = 10,
            },
            .end = .{
                .byte_offset = 24,
                .line = 0,
                .column = 24,
            },
            .message = "Callable should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 84,
                .line = 2,
                .column = 21,
            },
            .end = .{
                .byte_offset = 89,
                .line = 2,
                .column = 26,
            },
            .message = "Function argument should be snake_case",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("extern_not_good", result.problems[0].sliceSource(source));
}

test "general" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\
        \\fn not_good() void {}
        \\fn good() void {}
        \\fn alsoGood() void {}
        \\fn AlsoGood(T: type) type { return T; }
        \\fn NotGood() void {}
        \\
        \\fn here(Arg: u32, t: type, fn_call: *const fn (A: u32) void) t {
        \\fn_call(Arg);
        \\return @intCast(Arg);
        \\}
        \\
        \\fn alsoHere(arg: u32, T: type, fnCall: *const fn (a: u32) void) T {
        \\    fnCall(arg);
        \\    return @intCast(arg);
        \\}
    ;
    var config = Config{};
    var result = (try zlinter.testing.runRule(rule, zlinter.testing.paths.posix("path/to/file.zig"), source, .{
        .config = &config,
    })).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/file.zig"),
    );

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.results.LintProblem{
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 4,
                .line = 1,
                .column = 3,
            },
            .end = .{
                .byte_offset = 11,
                .line = 1,
                .column = 10,
            },
            .message = "Callable should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 106,
                .line = 5,
                .column = 3,
            },
            .end = .{
                .byte_offset = 112,
                .line = 5,
                .column = 9,
            },
            .message = "Callable should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 133,
                .line = 7,
                .column = 8,
            },
            .end = .{
                .byte_offset = 135,
                .line = 7,
                .column = 10,
            },
            .message = "Function argument should be snake_case",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 143,
                .line = 7,
                .column = 18,
            },
            .end = .{
                .byte_offset = 143,
                .line = 7,
                .column = 18,
            },
            .message = "Function argument of type should be TitleCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 152,
                .line = 7,
                .column = 27,
            },
            .end = .{
                .byte_offset = 158,
                .line = 7,
                .column = 33,
            },
            .message = "Function argument of function should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .byte_offset = 172,
                .line = 7,
                .column = 47,
            },
            .end = .{
                .byte_offset = 172,
                .line = 7,
                .column = 47,
            },
            .message = "Function argument should be snake_case",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("not_good", result.problems[0].sliceSource(source));
}

const std = @import("std");
const zlinter = @import("zlinter");
