//! Enforces that there are no uses of `@panic`.
//!
//! `@panic` forcibly stops the program at runtime — it should be a last resort.
//!
//! Panics can be replaced with:
//!
//! * Proper error handling (error types and try / catch)
//! * Precondition checks (std.debug.assert) that fail only in debug mode
//! * Compile-time checks (comptime) when possible
//!
//! Panics may be useful during early development, but leaving them in shipped code leads to:
//!
//! * Abrupt crashes that break user trust
//! * Hard-to-debug failures in production
//! * Missed opportunities for graceful recovery
//!
//! By default this will not flag `@panic` found in `test` blocks.
//!
//! **Good:**
//!
//! ```zig
//! pub fn divide(x: i32, y: i32) !i32 {
//!   if (y == 0) return error.DivideByZero;
//!   return x / y;
//! }
//! ```
//!
//! **Bad:**
//!
//! ```zig
//! pub fn divide(x: i32, y: i32) i32 {
//!   if (y == 0) @panic("Divide by zero!");
//!   return x / y;
//! }
//! ```
//!

/// Config for no_panic rule.
pub const Config = struct {
    /// The severity of using `@panic` (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Skip if found within `test { ... }` block.
    exclude_tests: bool = true,

    /// Skip `@panic(...)` calls where the decoded string content equals a given string (case sensitive).
    /// For example, maybe your application is happy to panic on OOM, so it
    /// would be reasonable to add "OOM" to the list here so `@panic("OOM")`
    /// is allowed.
    exclude_panic_with_content: []const []const u8 = &.{},
};

/// Builds and returns the no_panic rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_panic),
        .run = &run,
    };
}

/// Runs the no_panic rule.
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

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        if (!zlinter.ast.isBuiltinCallNamed(tree, node, "@panic")) continue :nodes;

        // if configured, skip if a parent is a test block
        if (config.exclude_tests and doc.isEnclosedInTestBlock(session, node))
            continue :nodes;

        // if configured, skip if panic has case sensitive string content matching
        if (try builtinHasParamContent(
            rule_arena,
            tree,
            node,
            config.exclude_panic_with_content,
        )) continue :nodes;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.dupe(u8, "`@panic` forcibly stops the program at runtime and should be avoided"),
        });
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

/// Returns true if the built call has a single argument that matches one of the
/// given contents after decoding the string literal. e.g., `@panic("OOM")`
/// and `@panic("O\x4fM")` both match `&.{"OOM"}`.
/// Contents are case sensitive
fn builtinHasParamContent(
    rule_arena: std.mem.Allocator,
    tree: Ast,
    node: Ast.Node.Index,
    contents: []const []const u8,
) !bool {
    if (contents.len == 0) return false;

    var buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node) orelse return false;
    if (params.len != 1) return false;

    const param = params[0];
    if (tree.nodeTag(param) != .string_literal) return false;

    for (contents) |c|
        if (try stringLiteralContentEquals(rule_arena, tree, param, c)) return true;
    return false;
}

fn stringLiteralContentEquals(
    rule_arena: std.mem.Allocator,
    tree: Ast,
    string_node: Ast.Node.Index,
    expected: []const u8,
) !bool {
    const token = tree.nodeMainToken(string_node);
    const raw = tree.tokenSlice(token);
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return false;

    const decoded = std.zig.string_literal.parseAlloc(rule_arena, raw) catch |err| switch (err) {
        error.InvalidLiteral => return false,
        error.OutOfMemory => return error.OutOfMemory,
    };

    return std.mem.eql(u8, decoded, expected);
}

test "excludes based on configurable contents" {
    // Bad cases:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() void { 
        \\  @panic("oom");
        \\}
    ,
        .{},
        Config{
            .exclude_panic_with_content = &.{
                "OOM", "other",
            },
        },
        &.{
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic("oom")
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() void { @panic("OTHER"); }
    ,
        .{},
        Config{
            .exclude_panic_with_content = &.{
                "OOM", "other",
            },
        },
        &.{
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic("OTHER")
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\ pub fn main() void {
        \\  @panic("O\x4fM");
        \\  @panic("");
        \\  @panic("a\"b");
        \\  @panic("OPM");
        \\}
    ,
        .{},
        Config{
            .exclude_panic_with_content = &.{
                "OOM", "", "a\"b",
            },
        },
        &.{
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic("OPM")
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
        },
    );

    // Good cases:
    inline for (&.{
        \\ @panic("OOM");
        ,
        \\ @panic("O\x4fM");
        ,
        \\ @panic("");
        ,
        \\ @panic("a\"b");
        ,
        \\ @panic("other");
        ,
        \\ const a = @abs(-10);
    }) |source|
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            "pub fn main() void { " ++ source ++ "}",
            .{},
            Config{
                .exclude_panic_with_content = &.{
                    "OOM", "other", "", "a\"b",
                },
            },
            &.{},
        );
}

test "no_panic reports malformed and unusual builtin calls" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\pub fn main() void {
        \\    @panic();
        \\}
        \\
        \\pub fn main2() void {
        \\    @panic("a", "b");
        \\}
        \\
        \\pub fn main3() void {
        \\    @panic(foo);
        \\}
        \\
        \\pub fn main4() void {
        \\    @panic(.{});
        \\}
        \\
        \\pub fn main5() void {
        \\    @abs();
        \\}
    ,
        .{ .allow_parse_errors = true },
        Config{},
        &.{
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic(.{})
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic(foo)
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic("a", "b")
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic()
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
        },
    );
}

test "no_panic" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    const source =
        \\pub fn main() void {
        \\  @panic("Main not implemented");
        \\}
        \\
        \\test {
        \\  @panic("test not implemented");
        \\}
    ;

    inline for (&.{ .warning, .@"error" }) |severity|
        try zlinter.testing.testRunRule(
            rule,
            source,
            .{},
            Config{
                .severity = severity,
            },
            &.{
                .{
                    .rule_id = "no_panic",
                    .severity = severity,
                    .slice =
                    \\@panic("Main not implemented")
                    ,
                    .message = "`@panic` forcibly stops the program at runtime and should be avoided",
                },
            },
        );

    // Off:
    try zlinter.testing.testRunRule(
        rule,
        source,
        .{},
        Config{
            .severity = .off,
        },
        &.{},
    );
}

test "no_panic reports test block panics when exclude_tests is false" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\test {
        \\    @panic("test not implemented");
        \\}
    ,
        .{},
        Config{
            .exclude_tests = false,
        },
        &.{
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .slice =
                \\@panic("test not implemented")
                ,
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
