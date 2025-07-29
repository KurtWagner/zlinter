//! Enforces that a function does not define too many positional arguments.
//!
//! Keeping positional argument lists short improves readability and encourages
//! concise designs.
//!
//! If the function is doing too many things, consider splitting it up
//! into smaller more focused functions. Alternatively, accept a struct with
//! appropriate defaults.

/// Config for max_positional_args rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// The max number of positional arguments. Functions with more than this
    /// many arguments will fail the rule.
    max: u8 = 5,

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
};

/// Builds and returns the max_positional_args rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.max_positional_args),
        .run = &run,
    };
}

/// Runs the max_positional_args rule.
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
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;

    var node: zlinter.shims.NodeIndexShim = .init(1);
    skip: while (node.index < tree.nodes.len) : (node.index += 1) {
        const fn_proto = fnProto(tree, &fn_buffer, node.toNodeIndex()) orelse continue :skip;

        if (config.exclude_extern and fn_proto.extern_export_inline_token != null) {
            const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
            if (token_tag == .keyword_extern) continue :skip;
        }

        if (config.exclude_export and fn_proto.extern_export_inline_token != null) {
            const token_tag = tree.tokens.items(.tag)[fn_proto.extern_export_inline_token.?];
            if (token_tag == .keyword_export) continue :skip;
        }

        if (fn_proto.ast.params.len <= config.max) continue :skip;

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, fn_proto.ast.params[0]),
            .end = .endOfNode(tree, fn_proto.ast.params[fn_proto.ast.params.len - 1]),
            .message = try std.fmt.allocPrint(allocator, "Exceeded maximum positional arguments of {d}.", .{config.max}),
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

inline fn fnProto(tree: std.zig.Ast, buffer: *[1]std.zig.Ast.Node.Index, node: std.zig.Ast.Node.Index) ?std.zig.Ast.full.FnProto {
    return switch (zlinter.shims.nodeTag(tree, node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buffer, node),
        .fn_proto_simple => tree.fnProtoSimple(buffer, node),
        else => null,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "export excluded" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\export fn exportToManyArgs(u32, u32) void;
    ;
    var config = Config{ .exclude_export = true, .max = 1 };
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
        \\export fn exportToManyArgs(u32, u32) void;
    ;
    var config = Config{ .exclude_export = false, .max = 1 };
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

test "extern excluded" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\extern fn externToManyArgs(u32, u32) void;
    ;
    var config = Config{ .exclude_extern = true, .max = 1 };
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
        \\extern fn externToManyArgs(u32, u32) void;
    ;
    var config = Config{ .exclude_extern = false, .max = 1 };
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

test "general" {
    std.testing.refAllDecls(@This());

    const source: [:0]const u8 =
        \\fn ok() void {}
        \\fn alsoOk(a1:u32, a2:u32, a3:u32, a4:u32, a5:u32) void {}
        \\fn noOk(a1:u32, a2:u32, a3:u32, a4:u32, a5:u32, a6:u32) void {}
    ;

    const rule = buildRule(.{});
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
        source,
        .{},
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
    );

    // TODO: This looks like a bug - should include a1 name in param:
    inline for (&.{"u32, a2:u32, a3:u32, a4:u32, a5:u32, a6:u32)"}, 0..) |slice, i| {
        try std.testing.expectEqualStrings(slice, result.problems[i].sliceSource(source));
    }

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "max_positional_args",
                .severity = .warning,
                .start = .{
                    .byte_offset = 85,
                    .line = 2,
                    .column = 11,
                },
                .end = .{
                    .byte_offset = 128,
                    .line = 2,
                    .column = 54,
                },
                .message = "Exceeded maximum positional arguments of 5.",
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
