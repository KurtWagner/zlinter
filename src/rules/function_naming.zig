//! Enforces naming conventions for functions

/// Config for function_naming rule.
pub const Config = struct {
    severity: zlinter.LintProblemSeverity = .@"error",

    /// Non-type functions
    function: zlinter.LintTextStyle = .camel_case,

    /// Type functions
    function_that_returns_type: zlinter.LintTextStyle = .title_case,
};

/// Builds and returns the function_naming rule.
pub fn buildRule(options: zlinter.LintRuleOptions) zlinter.LintRule {
    _ = options;

    return zlinter.LintRule{
        .rule_id = @tagName(.function_naming),
        .run = &run,
    };
}

/// Runs the function_naming rule.
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

    var node: zlinter.analyzer.NodeIndexShim = .init(1); // Skip root node at 0
    while (node.index < tree.nodes.len) : (node.index += 1) {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        if (namedFnProto(tree, &buffer, node.toNodeIndex())) |fn_proto| {
            const fn_name_token = fn_proto.name_token.?;
            const fn_name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(fn_name_token));
            const fn_returns_type = std.mem.eql(u8, tree.getNodeSource(switch (zlinter.version.zig) {
                .@"0.14" => fn_proto.ast.return_type,
                .@"0.15" => fn_proto.ast.return_type.unwrap().?,
            }), "type");

            const error_message: ?[]const u8 = msg: {
                if (fn_returns_type) {
                    const style = config.function_that_returns_type;
                    if (!style.check(fn_name)) {
                        break :msg try std.fmt.allocPrint(allocator, "Callable returning `type` should be {s}", .{style.name()});
                    }
                } else {
                    const style = config.function;
                    if (!style.check(fn_name)) {
                        break :msg try std.fmt.allocPrint(allocator, "Callable should be {s}", .{style.name()});
                    }
                }
                break :msg null;
            };

            if (error_message) |message| {
                try lint_problems.append(
                    allocator,
                    .{
                        .severity = config.severity,
                        .rule_id = rule.rule_id,
                        .start = .startOfToken(tree, fn_name_token),
                        .end = .endOfToken(tree, fn_name_token),
                        .message = message,
                    },
                );
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

/// Returns fn proto if node is fn proto and has a name token.
pub fn namedFnProto(tree: std.zig.Ast, buffer: *[1]std.zig.Ast.Node.Index, node: std.zig.Ast.Node.Index) ?std.zig.Ast.full.FnProto {
    if (switch (zlinter.analyzer.nodeTag(tree, node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buffer, node),
        .fn_proto_simple => tree.fnProtoSimple(buffer, node),
        else => null,
    }) |fn_proto| {
        if (fn_proto.name_token != null) return fn_proto;
    }
    return null;
}

test "run" {
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
        \\extern fn extern_not_good() void;
        \\extern fn externGood() void;
    ;
    var result = (try zlinter.testing.runRule(rule, "path/to/file.zig", source)).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        "path/to/file.zig",
    );

    try zlinter.testing.expectProblemsEqual(&[_]zlinter.LintProblem{
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .offset = 1,
                .line = 1,
                .column = 3,
            },
            .end = .{
                .offset = 22,
                .line = 1,
                .column = 10,
            },
            .message = "Callable should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .offset = 103,
                .line = 5,
                .column = 3,
            },
            .end = .{
                .offset = 123,
                .line = 5,
                .column = 9,
            },
            .message = "Callable should be camelCase",
        },
        .{
            .rule_id = "function_naming",
            .severity = .@"error",
            .start = .{
                .offset = 125,
                .line = 7,
                .column = 10,
            },
            .end = .{
                .offset = 158,
                .line = 7,
                .column = 24,
            },
            .message = "Callable should be camelCase",
        },
    }, result.problems);

    try std.testing.expectEqualStrings("fn not_good() void {}", result.problems[0].sliceSource(source));
}

const std = @import("std");
const zlinter = @import("zlinter");
