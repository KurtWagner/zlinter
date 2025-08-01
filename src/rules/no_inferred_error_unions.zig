//! Disallow using inferred error sets in function return types — always declare them explicitly.
//!
//! In Zig, when you write `!T` as a return type without an explicit error set
//! (e.g. `!void`), Zig infers the error set from whatever operations inside the
//! function can fail.
//!
//! This is powerful, but it can:
//!
//!  - Make APIs harder to understand - the possible errors aren’t visible at the signature.
//!  - Make refactoring risky - adding or changing a failing operation silently changes the function’s error type.
//!  - Lead to brittle dependencies - downstream callers may break if the inferred error set grows or changes.
//!
//! The goal of the rule is to keep error contracts clear and stable. If it can fail, say how.

/// Config for no_inferred_error_unions rule.
pub const Config = struct {
    /// The severity of inferred error unions (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Allow inferred error unions for private functions.
    allow_private: bool = true,

    /// Allow `anyerror` as the explicit error.
    allow_anyerror: bool = true,
};

/// Builds and returns the no_inferred_error_unions rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_inferred_error_unions),
        .run = &run,
    };
}

/// Runs the no_inferred_error_unions rule.
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

    const root: zlinter.shims.NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    var fn_decl_buffer: [1]std.zig.Ast.Node.Index = undefined;
    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const tag = zlinter.shims.nodeTag(tree, node.toNodeIndex());
        if (tag != .fn_decl) continue :skip;

        const fn_decl = tree.fullFnProto(&fn_decl_buffer, node.toNodeIndex()) orelse continue :skip;
        if (config.allow_private and isFnPrivate(tree, fn_decl)) continue :skip;

        const return_type = zlinter.shims.NodeIndexShim.initOptional(fn_decl.ast.return_type) orelse continue :skip;

        const return_type_tag = zlinter.shims.nodeTag(tree, return_type.toNodeIndex());
        switch (return_type_tag) {
            .error_union => if (config.allow_anyerror or
                !std.mem.eql(u8, tree.tokenSlice(tree.firstToken(return_type.toNodeIndex())), "anyerror"))
                continue :skip,
            .identifier => switch (tree.tokens.items(.tag)[tree.firstToken(return_type.toNodeIndex()) - 1]) {
                .bang => {},
                else => continue :skip,
            },
            else => continue :skip,
        }

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfToken(tree, tree.firstToken(node.toNodeIndex())),
            .end = .endOfNode(tree, return_type.toNodeIndex()),
            .message = try allocator.dupe(u8, "Function returns an inferred error union. Prefer an explicit error set"),
        });
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

fn isFnPrivate(tree: std.zig.Ast, fn_decl: std.zig.Ast.full.FnProto) bool {
    const visibility_token = fn_decl.visib_token orelse return true;
    return switch (tree.tokens.items(.tag)[visibility_token]) {
        .keyword_pub => false,
        else => true,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "no_inferred_error_unions - valid function declarations" {
    inline for (&.{
        \\pub fn pubGood() error{Always}!void {
        \\  return error.Always;
        \\}
        ,
        \\const Errors = error{Always};
        \\pub fn pubGood() Errors!void {
        \\  return error.Always;
        \\}
        ,
        \\pub fn pubAlsoAllowedByDefault() anyerror!void {
        \\return error.Always;
        \\}
        ,
        \\pub fn hasNoError() void {}
        ,
        \\fn privateAllowInferred() !void {
        \\ return error.Always;
        \\}
    }) |source| {
        const rule = buildRule(.{});
        var result = (try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/return_err.zig"),
            source,
            .{},
        ));
        defer if (result) |*r| r.deinit(std.testing.allocator);
        try std.testing.expectEqual(null, result);
    }
}

test "no_inferred_error_unions - Invalid function declarations - defaults" {
    const rule = buildRule(.{});
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/return_err.zig"),
        \\pub fn inferred() !void {
        \\  return error.Always;
        \\}
    ,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/return_err.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .start = .{
                    .byte_offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .byte_offset = 23,
                    .line = 0,
                    .column = 23,
                },
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
        result.problems,
    );
}

test "no_inferred_error_unions - Invalid function declarations - allow_private = false" {
    const rule = buildRule(.{});
    var config = Config{ .allow_private = false };
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/return_err.zig"),
        \\fn inferred() !void {
        \\  return error.Always;
        \\}
    ,
        .{ .config = &config },
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/return_err.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .start = .{
                    .byte_offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .byte_offset = 19,
                    .line = 0,
                    .column = 19,
                },
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
        result.problems,
    );
}

test "no_inferred_error_unions - Invalid function declarations - allow_anyerror = false" {
    const rule = buildRule(.{});
    var config = Config{ .allow_anyerror = false };
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/return_err.zig"),
        \\pub fn inferred() anyerror!void {
        \\  return error.Always;
        \\}
    ,
        .{ .config = &config },
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/return_err.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_inferred_error_unions",
                .severity = .warning,
                .start = .{
                    .byte_offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .byte_offset = 31,
                    .line = 0,
                    .column = 31,
                },
                .message = "Function returns an inferred error union. Prefer an explicit error set",
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
