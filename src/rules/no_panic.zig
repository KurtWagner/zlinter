//! Enforces that there are no uses of `@panic`.
//!
//! `@panic` forcibly stops the program at runtime — it should be a last resort.
//!
//! Panics can be replaced with:
//!
//! - Proper error handling (error types and try / catch)
//! - Precondition checks (std.debug.assert) that fail only in debug mode
//! - Compile-time checks (comptime) when possible
//!
//! Panics may be useful during early development, but leaving them in shipped code leads to:
//!
//! - Abrupt crashes that break user trust
//! - Hard-to-debug failures in production
//! - Missed opportunities for graceful recovery
//!
//! By default this will not flag `@panic` found in `test` blocks.
//!
//! **Good:**
//!
//! ```zig
//! pub fn divide(x: i32, y: i32) i32 {
//!   if (y == 0) @panic("Divide by zero!");
//!   return x / y;
//! }
//! ```
//!
//! **Bad:**
//!
//! ```zig
//! pub fn divide(x: i32, y: i32) !i32 {
//!   if (y == 0) return error.DivideByZero;
//!   return x / y;
//! }
//! ```
//!

// TODO: exclude_test flags should also include `if (builtin.is_test)` checks
// TODO: exclude_debug should we add option to exclude when guarded by `if (builtin.mode == .Debug)`?

/// Config for no_panic rule.
pub const Config = struct {
    /// The severity of using `@panic` (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,

    /// Skip if found within `test { ... }` block.
    exclude_tests: bool = true,
};

/// Builds and returns the no_panic rule.
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_panic),
        .run = &run,
    };
}

/// Runs the no_panic rule.
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

    skip: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const tag = zlinter.shims.nodeTag(tree, node.toNodeIndex());
        switch (tag) {
            .builtin_call_two,
            .builtin_call_two_comma,
            .builtin_call,
            .builtin_call_comma,
            => {
                const main_token = zlinter.shims.nodeMainToken(tree, node.toNodeIndex());
                if (!std.mem.eql(u8, tree.tokenSlice(main_token), "@panic")) continue :skip;
            },
            else => continue :skip,
        }

        // if configured, skip if a parent is a test block
        if (config.exclude_tests) {
            var next_parent = connections.parent;
            while (next_parent) |parent| {
                if (zlinter.shims.nodeTag(tree, parent) == .test_decl) continue :skip;

                next_parent = doc.lineage.items(.parent)[zlinter.shims.NodeIndexShim.init(parent).index];
            }
        }

        try lint_problems.append(allocator, .{
            .rule_id = rule.rule_id,
            .severity = config.severity,
            .start = .startOfNode(tree, node.toNodeIndex()),
            .end = .endOfNode(tree, node.toNodeIndex()),
            .message = try allocator.dupe(u8, "`@panic` forcibly stops the program at runtime and should be avoided"),
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

test "no_panic" {
    std.testing.refAllDecls(@This());

    const rule = buildRule(.{});
    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/panic.zig"),
        \\pub fn main() void {
        \\  @panic("Main not implemented");
        \\}
        \\
        \\test {
        \\  @panic("test not implemented");
        \\}
        ,
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/panic.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "no_panic",
                .severity = .warning,
                .start = .{
                    .byte_offset = 23,
                    .line = 1,
                    .column = 2,
                },
                .end = .{
                    .byte_offset = 53,
                    .line = 1,
                    .column = 32,
                },
                .message = "`@panic` forcibly stops the program at runtime and should be avoided",
                .disabled_by_comment = false,
                .fix = null,
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
