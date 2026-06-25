//! Enforces no uses of `undefined`. There are some valid use case, in which
//! case uses should disable the line with an explanation.

/// Config for no_undefined rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Skip if found inside an enclosing function whose name exactly matches
    /// one of these names, case-insensitively.
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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        if (tree.nodeTag(node) != .identifier) continue :nodes;
        if (!std.mem.eql(u8, tree.getNodeSource(node), "undefined"))
            continue :nodes;

        var decl_var_name: ?[]const u8 = null;
        if (doc.lineage.items(.parent)[@intFromEnum(node)]) |parent| {
            if (tree.fullVarDecl(parent)) |var_decl| {
                if (tree.tokens.items(.tag)[var_decl.ast.mut_token] == .keyword_var) {
                    const name_token = var_decl.ast.mut_token + 1;
                    const name = tree.tokenSlice(name_token);
                    decl_var_name = name;

                    for (config.exclude_var_decl_name_equals) |var_name| {
                        if (std.ascii.eqlIgnoreCase(name, var_name))
                            continue :nodes;
                    }
                    for (config.exclude_var_decl_name_ends_with) |var_name| {
                        if (std.ascii.endsWithIgnoreCase(name, var_name))
                            continue :nodes;
                    }
                }
            }
        }

        // We expect any undefined with a test to simply be ignored as really we expect
        // the test to fail if there's issues
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node))
            continue :nodes;

        var next_parent = connections.parent;
        while (next_parent) |parent| {
            // If assigned undefined in an exempt function, ignore as it's a
            // common pattern to assign undefined after freeing memory.
            if (config.exclude_in_fn.len > 0) {
                if (tree.fullFnProto(&fn_proto_buffer, parent)) |fn_proto| {
                    if (fn_proto.name_token) |name_token| {
                        for (config.exclude_in_fn) |skip_fn_name| {
                            if (std.ascii.eqlIgnoreCase(tree.tokenSlice(name_token), skip_fn_name))
                                continue :nodes;
                        }
                    }
                }
            }

            // Look at lineage of containing block to see if "init" (or
            // configured method) is called on the var declaration set to
            // undefined. e.g., `this_was_undefined.init()`
            if (decl_var_name) |var_name| {
                if (switch (tree.nodeTag(parent)) {
                    .block_two,
                    .block_two_semicolon,
                    .block,
                    .block_semicolon,
                    => true,
                    else => false,
                }) {
                    var block_it = try doc.nodeLineageIterator(parent, rule_arena);

                    while (try block_it.next()) |block_tuple| {
                        const block_node, _ = block_tuple;
                        if (zlinter.ast.isMethodCallOnIdentifier(
                            tree,
                            block_node,
                            var_name,
                            config.init_method_names,
                        )) continue :nodes;
                    }
                }
            }

            next_parent = doc.lineage.items(.parent)[@intFromEnum(parent)];
        }

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.dupe(u8, "Take care when using `undefined`"),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            lint_problems.items,
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

test "exclude in fn" {
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\fn deinit() void {
            \\  var ok: u32 = undefined;
            \\}
            \\
            \\fn notDeinit() void {
            \\  var should_warn: u32 = undefined;
            \\}
            \\
            \\fn my_deinit_helper() void {
            \\  var also_warn: u32 = undefined;
            \\}
        ,
            .{},
            Config{
                .severity = severity,
            },
            &.{
                .{
                    .rule_id = "no_undefined",
                    .severity = severity,
                    .slice = "undefined",
                    .message = "Take care when using `undefined`",
                },
                .{
                    .rule_id = "no_undefined",
                    .severity = severity,
                    .slice = "undefined",
                    .message = "Take care when using `undefined`",
                },
            },
        );

        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\fn cleanup() void {
            \\  var ok: u32 = undefined;
            \\}
            \\
            \\fn teardown() void {
            \\  var also_ok: u32 = undefined;
            \\}
            \\
            \\fn cleanupNow() void {
            \\  var should_warn: u32 = undefined;
            \\}
        ,
            .{},
            Config{
                .severity = severity,
                .exclude_in_fn = &.{ "cleanup", "teardown" },
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

test "init method exemption requires call" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() void {
        \\     var assigned_field: SomeType = undefined;
        \\     _ = assigned_field.init;
        \\
        \\     var captured_field: SomeType = undefined;
        \\     const f = captured_field.init;
        \\     _ = f;
        \\
        \\     var condition_field: SomeType = undefined;
        \\     if (condition_field.init) {}
        \\ }
    ,
        .{},
        Config{
            .severity = .warning,
            .init_method_names = &.{"init"},
        },
        &.{
            .{
                .rule_id = "no_undefined",
                .severity = .warning,
                .slice = "undefined",
                .message = "Take care when using `undefined`",
            },
            .{
                .rule_id = "no_undefined",
                .severity = .warning,
                .slice = "undefined",
                .message = "Take care when using `undefined`",
            },
            .{
                .rule_id = "no_undefined",
                .severity = .warning,
                .slice = "undefined",
                .message = "Take care when using `undefined`",
            },
        },
    );
}

test "init method exemption allows call forms" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() !void {
        \\     var direct_call: SomeType = undefined;
        \\     direct_call.init();
        \\
        \\     var try_call: SomeType = undefined;
        \\     try try_call.init();
        \\
        \\     var assigned_call: SomeType = undefined;
        \\     _ = assigned_call.init();
        \\ }
    ,
        .{},
        Config{
            .severity = .warning,
            .init_method_names = &.{"init"},
        },
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
