//! Disallows empty code blocks `{}` unless explicitly allowed or documented.
//!
//! Empty blocks are often a sign of incomplete or accidentally removed code.
//! They can make intent unclear and mislead maintainers into thinking logic
//! is missing.
//!
//! In some cases, empty blocks are intentional (e.g. placeholder, scoping, or
//! looping constructs). This rule helps distinguish between accidental
//! emptiness and intentional no-op by requiring either a configuration
//! exception or a comment.
//!
//! Whitespace-only blocks are reported. Blocks containing only comments are
//! treated as documented no-op blocks and are allowed.
//!
//! For example,
//!
//! ```zig
//! // OK - as comment within block.
//! if (something) {
//!   // do nothing
//! } else {
//!   doThing();
//! }
//! ```

const problem_msg_template = "Empty {s} blocks are discouraged. If deliberately empty, include a comment inside the block.";

/// Config for no_empty_block rule.
pub const Config = struct {
    /// Severity for empty `if` blocks
    if_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `if` else blocks
    if_else_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `while` blocks
    while_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty `while` else blocks
    while_else_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty `for` blocks
    for_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `for` else blocks
    for_else_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `catch` blocks
    catch_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty switch case blocks
    switch_case_block: zlinter.rules.LintProblemSeverity = .off,

    /// Severity for empty `defer` blocks
    defer_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `errdefer` blocks
    errdefer_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `fn` declaration blocks
    fn_decl_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Allow empty function bodies for ABI/runtime/linkage stubs.
    ///
    /// This covers cases where an empty function exists primarily to provide
    /// a required symbol, calling convention, export, or runtime hook.
    allow_empty_abi_stubs: bool = true,

    /// Severity for empty `test` blocks
    test_block: zlinter.rules.LintProblemSeverity = .@"error",

    /// Severity for empty `comptime` blocks
    comptime_block: zlinter.rules.LintProblemSeverity = .@"error",
};

/// Builds and returns the no_empty_block rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_empty_block),
        .run = &run,
    };
}

/// Runs the no_empty_block rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;
    var fn_proto_buffer: [1]Ast.Node.Index = undefined;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, _ = tuple;

        if (declBlock(tree, node)) |decl_block| {
            const severity = switch (decl_block.kind) {
                .fn_decl => config.fn_decl_block,
                .test_decl => config.test_block,
                .comptime_block => config.comptime_block,
            };
            if (severity != .off and
                isWhitespaceOnlyBlock(tree, decl_block.block) and
                !(decl_block.kind == .fn_decl and
                    config.allow_empty_abi_stubs and
                    isAbiStubFnDecl(tree, node, &fn_proto_buffer)))
            {
                try lint_problems.append(session_arena, .{
                    .rule_id = rule.rule_id,
                    .severity = severity,
                    .start = .startOfToken(tree, tree.firstToken(decl_block.block)),
                    .end = .endOfToken(tree, tree.lastToken(decl_block.block)),
                    .message = try std.fmt.allocPrint(
                        session_arena,
                        problem_msg_template,
                        .{decl_block.kind.name()},
                    ),
                });
            }
            continue :nodes;
        }

        const statement = zlinter.ast.fullStatement(tree, node) orelse continue :nodes;
        var block_candidates_buffer: [2]BlockCandidate = undefined;
        var block_candidates: std.ArrayList(BlockCandidate) = .initBuffer(&block_candidates_buffer);

        switch (statement) {
            .@"if" => |info| {
                block_candidates.appendAssumeCapacity(.{
                    .node = info.ast.then_expr,
                    .severity = config.if_block,
                    .label = "if body",
                });
                if (info.ast.else_expr.unwrap()) |n| {
                    block_candidates.appendAssumeCapacity(.{
                        .node = n,
                        .severity = config.if_else_block,
                        .label = "if else",
                    });
                }
            },
            .@"while" => |info| {
                block_candidates.appendAssumeCapacity(.{
                    .node = info.ast.then_expr,
                    .severity = config.while_block,
                    .label = "while body",
                });
                if (info.ast.else_expr.unwrap()) |n| {
                    block_candidates.appendAssumeCapacity(.{
                        .node = n,
                        .severity = config.while_else_block,
                        .label = "while else",
                    });
                }
            },
            .@"for" => |info| {
                block_candidates.appendAssumeCapacity(.{
                    .node = info.ast.then_expr,
                    .severity = config.for_block,
                    .label = "for body",
                });
                if (info.ast.else_expr.unwrap()) |n| {
                    block_candidates.appendAssumeCapacity(.{
                        .node = n,
                        .severity = config.for_else_block,
                        .label = "for else",
                    });
                }
            },
            .switch_case => |info| block_candidates.appendAssumeCapacity(.{
                .node = info.ast.target_expr,
                .severity = config.switch_case_block,
                .label = "switch case",
            }),
            .@"catch" => |expr_node| block_candidates.appendAssumeCapacity(.{
                .node = expr_node,
                .severity = config.catch_block,
                .label = "catch",
            }),
            .@"defer" => |expr_node| block_candidates.appendAssumeCapacity(.{
                .node = expr_node,
                .severity = config.defer_block,
                .label = "defer",
            }),
            .@"errdefer" => |expr_node| block_candidates.appendAssumeCapacity(.{
                .node = expr_node,
                .severity = config.errdefer_block,
                .label = "errdefer",
            }),
        }

        block_candidates: for (block_candidates.items) |candidate| {
            if (candidate.severity == .off) continue :block_candidates;

            const expr_node = candidate.node;

            // Ignore here as it'll be processed in the outer loop.
            if (zlinter.ast.fullStatement(tree, expr_node) != null) continue :block_candidates;

            if (!isWhitespaceOnlyBlock(tree, expr_node)) continue :block_candidates;

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = candidate.severity,
                .start = .startOfToken(tree, tree.firstToken(expr_node)),
                .end = .endOfToken(tree, tree.lastToken(expr_node)),
                .message = try std.fmt.allocPrint(
                    session_arena,
                    problem_msg_template,
                    .{candidate.label},
                ),
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        )
    else
        null;
}

fn isWhitespaceOnlyBlock(tree: Ast, node: Ast.Node.Index) bool {
    const is_block = switch (tree.nodeTag(node)) {
        .block,
        .block_semicolon,
        .block_two,
        .block_two_semicolon,
        => true,
        else => false,
    };
    if (!is_block) return false;

    const first_token = tree.firstToken(node);
    if (tree.tokenTag(first_token) != .l_brace) return false;

    const last_token = blockClosingBraceToken(tree, node) orelse return false;
    const start = tree.tokenStart(first_token) + tree.tokenSlice(first_token).len;
    const end = tree.tokenStart(last_token);
    if (start > end) return false;

    // Comments are intentionally treated as documentation, so any non-whitespace
    // byte between braces means the block is allowed.
    for (start..end) |i| {
        if (!std.ascii.isWhitespace(tree.source[i])) {
            return false;
        }
    }
    return true;
}

fn isAbiStubFnDecl(tree: Ast, node: Ast.Node.Index, fn_proto_buffer: *[1]Ast.Node.Index) bool {
    const fn_proto = tree.fullFnProto(fn_proto_buffer, node) orelse return false;

    if (fn_proto.name_token) |name_token| {
        if (tree.tokenTag(name_token) == .identifier and
            std.mem.startsWith(u8, tree.tokenSlice(name_token), "__"))
            return true;
    }

    if (fn_proto.extern_export_inline_token) |token|
        if (tree.tokenTag(token) == .keyword_export) return true;

    if (fn_proto.ast.callconv_expr != .none) return true;
    if (fn_proto.ast.section_expr != .none) return true;

    return false;
}

fn blockClosingBraceToken(tree: Ast, node: Ast.Node.Index) ?Ast.TokenIndex {
    const first_token = tree.firstToken(node);
    var token = tree.lastToken(node);

    while (true) {
        if (tree.tokenTag(token) == .r_brace or std.mem.eql(u8, tree.tokenSlice(token), "}")) {
            return token;
        }

        if (token == first_token) return null;
        token -= 1;
    }
}

const DeclBlock = struct {
    block: Ast.Node.Index,
    kind: Kind,

    const Kind = enum {
        fn_decl,
        test_decl,
        comptime_block,

        fn name(self: Kind) []const u8 {
            return switch (self) {
                .fn_decl => "function declaration",
                .test_decl => "test",
                .comptime_block => "comptime",
            };
        }
    };
};

const BlockCandidate = struct {
    node: Ast.Node.Index,
    severity: zlinter.rules.LintProblemSeverity,
    label: []const u8,
};

fn declBlock(tree: Ast, node: Ast.Node.Index) ?DeclBlock {
    return switch (tree.nodeTag(node)) {
        .fn_decl => .{
            .block = tree.nodeData(node).node_and_node.@"1",
            .kind = .fn_decl,
        },
        .test_decl => .{
            .block = tree.nodeData(node).opt_token_and_node[1],
            .kind = .test_decl,
        },
        .@"comptime" => .{
            .block = tree.nodeData(node).node,
            .kind = .comptime_block,
        },
        else => null,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "if blocks" {
    const source =
        \\pub fn main() void {
        \\ if (true) {} else {
        \\  // Deliberate
        \\ }
        \\
        \\ if (false) {
        \\  return;
        \\ } else {}
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{
                .if_block = severity,
                .if_else_block = severity,
            },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .if_block = .off, .if_else_block = .off },
        &.{},
    );
}

test "if branch severities are independent" {
    const source =
        \\pub fn main() void {
        \\    if (a) {} else {}
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_block = .@"error",
            .if_else_block = .off,
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_block = .off,
            .if_else_block = .@"error",
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );
}

test "while blocks" {
    const source =
        \\pub fn main() void {
        \\ var i: u32 = 0;
        \\ while (i > 1) {} else {}
        \\
        \\ while (i < 10) : (i += 1) {
        \\   // deliberate
        \\ } else {
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{
                .while_block = severity,
                .while_else_block = severity,
            },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\ }
                    ,
                    .message = "Empty while else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty while body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty while else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .while_block = .off, .while_else_block = .off },
        &.{},
    );
}

test "while branch severities are independent" {
    const source =
        \\pub fn main() void {
        \\    var i: u32 = 0;
        \\    while (i < 10) : (i += 1) {} else {}
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .while_block = .@"error",
            .while_else_block = .off,
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty while body blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .while_block = .off,
            .while_else_block = .@"error",
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty while else blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );
}

test "for blocks" {
    const source =
        \\pub fn main() void {
        \\ for (0..1) |_| {} else {}
        \\
        \\ for (0..1) |_| {
        \\  // deliberate
        \\ } else {
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{
                .for_block = severity,
                .for_else_block = severity,
            },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\ }
                    ,
                    .message = "Empty for else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty for body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty for else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .for_block = .off, .for_else_block = .off },
        &.{},
    );
}

test "for branch severities are independent" {
    const source =
        \\pub fn main() void {
        \\    const items = [_]u8{1};
        \\    for (items) |_| {} else {}
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .for_block = .@"error",
            .for_else_block = .off,
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty for body blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .for_block = .off,
            .for_else_block = .@"error",
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty for else blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );
}

test "commented else block is allowed" {
    const source =
        \\pub fn main() void {
        \\    if (a) {
        \\        doThing();
        \\    } else {
        \\        // deliberately ignored
        \\    }
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_block = .@"error",
            .if_else_block = .@"error",
        },
        &.{},
    );
}

test "nested statement bodies" {
    const source =
        \\pub fn main() void {
        \\    const items = [_]u8{1};
        \\    if (true) if (true) {} else {};
        \\    while (true) if (true) {} else {};
        \\    for (items) |_| if (true) {} else {};
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{
                .if_block = severity,
                .while_block = severity,
                .for_block = severity,
                .if_else_block = severity,
                .while_else_block = severity,
                .for_else_block = severity,
            },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty if else blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }
}

test "defer blocks" {
    const source =
        \\pub fn main() void {
        \\ defer {}
        \\
        \\ defer {
        \\
        \\ }
        \\
        \\ defer {
        \\  // Deliberate - maybe a TODO to cleanup
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .defer_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty defer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty defer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .defer_block = .off },
        &.{},
    );
}

test "errdefer blocks" {
    const source =
        \\pub fn main() void {
        \\ errdefer {}
        \\
        \\ errdefer {
        \\
        \\ }
        \\
        \\ errdefer {
        \\  // Deliberate - maybe a TODO to cleanup
        \\ }
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .errdefer_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty errdefer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty errdefer blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .errdefer_block = .off },
        &.{},
    );
}

test "catch blocks" {
    const source =
        \\pub fn main() void {
        \\ something() catch {};
        \\
        \\ something() catch {
        \\
        \\ };
        \\
        \\ something() catch {
        \\  // Deliberate - maybe a TODO to cleanup
        \\ };
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .catch_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\ }
                    ,
                    .message = "Empty catch blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty catch blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .catch_block = .off },
        &.{},
    );
}

test "switch case blocks" {
    const source =
        \\pub fn main() void {
        \\ const something: enum { a, b, c } = .a;
        \\ switch (something) {
        \\     .a => {},
        \\     .b => {
        \\
        \\     },
        \\     .c => {
        \\         // Ignore
        \\     },
        \\ }
        \\ }
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .switch_case_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice =
                    \\{
                    \\
                    \\     }
                    ,
                    .message = "Empty switch case blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty switch case blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .switch_case_block = .off },
        &.{},
    );
}

test "function declaration blocks" {
    const source =
        \\pub fn empty() void {}
        \\
        \\fn alsoEmpty() void {}
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .fn_decl_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    // Off:
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .fn_decl_block = .off },
        &.{},
    );
}

test "commented empty function declaration block is allowed" {
    const source =
        \\pub fn alsoEmpty() void {
        \\    // Ignore
        \\}
    ;
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .fn_decl_block = .@"error" },
        &.{},
    );
}

test "empty ABI stubs are allowed by default" {
    const source =
        \\pub fn __aeabi_unwind_cpp_pr2() callconv(.{ .arm_aapcs = .{} }) void {}
        \\export fn exported_noop() void {}
        \\pub export fn public_exported_noop() void {}
        \\pub fn __runtime_hook() linksection(".text.special") void {}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{},
        &.{},
    );
}

test "empty ABI stubs are reported when disabled" {
    const source =
        \\pub fn __aeabi_unwind_cpp_pr2() callconv(.{ .arm_aapcs = .{} }) void {}
        \\export fn exported_noop() void {}
        \\pub export fn public_exported_noop() void {}
        \\pub fn __runtime_hook() linksection(".text.special") void {}
    ;

    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{
                .fn_decl_block = severity,
                .allow_empty_abi_stubs = false,
            },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty function declaration blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }
}

test "empty non-function blocks are still reported" {
    const source =
        \\pub fn main() void {
        \\    if (true) {}
        \\}
    ;

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{
            .if_block = .@"error",
            .allow_empty_abi_stubs = true,
        },
        &.{
            .{
                .rule_id = "no_empty_block",
                .severity = .@"error",
                .slice = "{}",
                .message = "Empty if body blocks are discouraged. If deliberately empty, include a comment inside the block.",
            },
        },
    );
}

test "test blocks" {
    const source =
        \\test {}
        \\
        \\test "name" {}
        \\
        \\test {
        \\    // deliberate
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .test_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty test blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty test blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .test_block = .off },
        &.{},
    );
}

test "comptime blocks" {
    const source =
        \\comptime {}
        \\
        \\comptime {
        \\    // deliberate
        \\}
    ;
    inline for (&.{ .warning, .@"error" }) |severity| {
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            source,
            .{},
            Config{ .comptime_block = severity },
            &.{
                .{
                    .rule_id = "no_empty_block",
                    .severity = severity,
                    .slice = "{}",
                    .message = "Empty comptime blocks are discouraged. If deliberately empty, include a comment inside the block.",
                },
            },
        );
    }

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        source,
        .{},
        Config{ .comptime_block = .off },
        &.{},
    );
}

test "blockClosingBraceToken handles trailing semicolons" {
    const source =
        \\pub fn main() void {
        \\    if (true) {};
        \\}
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    const block = try zlinter.testing.expectSingleNodeOfTag(tree, &.{.block_two_semicolon});
    try std.testing.expect(blockClosingBraceToken(tree, block) != null);
    const closing_brace = blockClosingBraceToken(tree, block).?;
    try std.testing.expectEqualStrings("}", tree.tokenSlice(closing_brace));
    try std.testing.expect(!isWhitespaceOnlyBlock(tree, block));
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
