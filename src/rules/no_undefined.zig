//! Enforces no uses of `undefined`. There are some valid use case, in which
//! case uses should disable the line with an explanation.

/// Config for no_undefined rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Skip if found in a function call (case-insenstive).
    exclude_in_fn: []const []const u8 = &.{"deinit"},

    /// Skip if found within `test { ... }` block.
    exclude_tests: bool = true,

    /// Skips var declarations that name equals (case-insensitive, for `var`, not `const`).
    exclude_var_decl_name_equals: []const []const u8 = &.{},

    /// Skips var declarations that name ends in (case-insensitive, for `var`, not `const`).
    exclude_var_decl_name_ends_with: []const []const u8 = &.{
        "memory",
        "mem",
        "buffer",
        "buf",
        "buff",
    },

    /// Skips when the undefined variable has this method called on it.
    init_method_names: []const []const u8 = &.{ "init", "initialize", "initialise" },
};

/// Builds and returns the no_undefined rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_undefined),
        .run = &run,
    };
}

/// Runs the no_undefined rule.
fn run(
    rule: zlinter.rules.LintRule,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = shims.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(allocator);

    const tree = doc.handle.tree;

    const root: NodeIndexShim = .root;
    var it = try doc.nodeLineageIterator(root, allocator);
    defer it.deinit();

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        if (shims.nodeTag(tree, node.toNodeIndex()) != .identifier) continue :nodes;
        if (!std.mem.eql(u8, tree.getNodeSource(node.toNodeIndex()), "undefined")) continue :nodes;

        var decl_var_name: ?[]const u8 = null;
        if (doc.lineage.items(.parent)[node.index]) |parent| {
            if (tree.fullVarDecl(parent)) |var_decl| {
                if (tree.tokens.items(.tag)[var_decl.ast.mut_token] == .keyword_var) {
                    const name_token = var_decl.ast.mut_token + 1;
                    const name = tree.tokenSlice(name_token);
                    decl_var_name = name;

                    for (config.exclude_var_decl_name_equals) |var_name| {
                        if (std.ascii.eqlIgnoreCase(name, var_name)) continue :nodes;
                    }
                    for (config.exclude_var_decl_name_ends_with) |var_name| {
                        if (std.ascii.endsWithIgnoreCase(name, var_name)) continue :nodes;
                    }
                }
            }
        }

        // We expect any undefined with a test to simply be ignored as really we expect
        // the test to fail if there's issues
        if (config.exclude_tests and doc.isEnclosedInTestBlock(node)) continue :nodes;

        var next_parent = connections.parent;
        while (next_parent) |parent| {
            // If assigned undefined in a deinit, ignore as it's a common pattern
            // assign undefined after freeing memory
            if (config.exclude_in_fn.len > 0) {
                if (tree.fullFnProto(&fn_proto_buffer, parent)) |fn_proto| {
                    if (fn_proto.name_token) |name_token| {
                        for (config.exclude_in_fn) |skip_fn_name| {
                            if (std.ascii.endsWithIgnoreCase(tree.tokenSlice(name_token), skip_fn_name)) continue :nodes;
                        }
                    }
                }
            }

            // Look at lineage of containing block to see if "init" (or
            // configured method) is called on the var declaration set to
            // undefined. e.g., `this_was_undefined.init()`
            if (decl_var_name) |var_name| {
                if (switch (shims.nodeTag(tree, parent)) {
                    .block_two,
                    .block_two_semicolon,
                    .block,
                    .block_semicolon,
                    => true,
                    else => false,
                }) {
                    var block_it = try doc.nodeLineageIterator(NodeIndexShim.init(parent), allocator);
                    defer block_it.deinit();

                    while (try block_it.next()) |block_tuple| {
                        const block_node, _ = block_tuple;
                        if (shims.nodeTag(tree, block_node.toNodeIndex()) == .field_access) {
                            const node_data = shims.nodeData(tree, block_node.toNodeIndex());
                            const lhs_node, const identifier_token = switch (zlinter.version.zig) {
                                .@"0.14" => .{ node_data.lhs, node_data.rhs },
                                .@"0.15", .@"0.16" => .{ node_data.node_and_token.@"0", node_data.node_and_token.@"1" },
                            };
                            const lhs_source = tree.getNodeSource(lhs_node);
                            if (std.mem.eql(u8, lhs_source, var_name)) {
                                const identifier_name = tree.tokenSlice(identifier_token);
                                for (config.init_method_names) |init_name| {
                                    if (std.mem.eql(u8, identifier_name, init_name)) {
                                        continue :nodes;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            next_parent = doc.lineage.items(.parent)[NodeIndexShim.init(parent).index];
        }

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node.toNodeIndex()),
            .end = .endOfNode(tree, node.toNodeIndex()),
            .message = try allocator.dupe(u8, "Take care when using `undefined`"),
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

test {
    std.testing.refAllDecls(@This());
}

test "exclude configs" {
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\pub fn main() void {
            \\  var buffer:[10]u8 = undefined; // ok
            \\  var me_excluded:SomeType = undefined; // ok
            \\  var not_ok: u32 = undefined;
            \\}
            \\
            \\fn meExcluded() void {
            \\  var ok: u32 = undefined;
            \\}
        ,
            .{},
            Config{
                .severity = severity,
                .exclude_var_decl_name_equals = &.{"buffer"},
                .exclude_var_decl_name_ends_with = &.{"excluded"},
                .exclude_in_fn = &.{"meExcluded"},
            },
            &.{
                .{
                    .rule_id = "no_undefined",
                    .severity = severity,
                    .slice = "undefined",
                    .message = "Take care when using `undefined`",
                },
            },
        );
    }
}

test "off" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\  var not_ok: u32 = undefined;
        \\}
    ,
        .{},
        Config{ .severity = .off },
        &.{},
    );
}

test "exclude tests" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ test {
        \\     var not_ok: SomeType = undefined;
        \\ }
    ,
        .{},
        Config{
            .severity = .warning,
            .exclude_tests = false,
        },
        &.{
            .{
                .rule_id = "no_undefined",
                .severity = .warning,
                .slice = "undefined",
                .message = "Take care when using `undefined`",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ test {
        \\     var not_ok: SomeType = undefined;
        \\ }
    ,
        .{},
        Config{
            .severity = .warning,
            .exclude_tests = true,
        },
        &.{},
    );
}

test "init methods" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() void {
        \\     var not_ok: SomeType = undefined;
        \\     not_ok.notInit();
        \\ }
    ,
        .{},
        Config{
            .severity = .warning,
            .init_method_names = &.{ "init", "initialize" },
        },
        &.{
            .{
                .rule_id = "no_undefined",
                .severity = .warning,
                .slice = "undefined",
                .message = "Take care when using `undefined`",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() void {
        \\     var ok: SomeType = undefined;
        \\     ok.init();
        \\     var also_ok: SomeType = undefined;
        \\     also_ok.initialize();
        \\ }
    ,
        .{},
        Config{
            .severity = .warning,
            .init_method_names = &.{ "init", "initialize" },
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
const NodeIndexShim = zlinter.shims.NodeIndexShim;
const Ast = std.zig.Ast;
