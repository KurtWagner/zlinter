//! Disallow `undefined` in questionable situations.
//!
//! `undefined` is unsafe to overuse because it creates storage without a valid
//! value. If that value is read before every relevant byte/field has been
//! written, the program may observe garbage data and have unpredictive behaviour
//!
//! Disallowed situations:
//!
//! * Returning `undefined` from a function - Return a real value, optional `null`, or an
//!   explicit error instead.
//! * Breaking `undefined` from a block - Break a real value or optional instead.
//! * Initializing an optional to `undefined` -  Use `null` instead.
//! * Initializing an enum or tagged union to `undefined` - Use a meaningful tag
//!   such as `.none` or `.unspecified` instead.
//! * Initializing a primitive scalar to `undefined` - Use a meaningful zero/false
//!   value or make it optional and use `null` instead.
//! * Initializing a `const` to `undefined` - Use a real value, optional or make the
//!   declaration mutable if delayed initialization is intentional.
//! * Initializing a pointer to `undefined` - Restructure the initialization and use a valid pointer, or make it
//!   optional and use `null`.
//!
//! Some ok uses of `undefined` are:
//!
//! * Scratch buffers that are filled before reading:
//!
//!   ```zig
//!   var buffer: [1024]u8 = undefined;
//!   const message = try bufPrint(&buffer, "Hello {s}", .{name});
//!   ```
//!
//! * Out-parameters that are populated by another method:
//!
//!   ```zig
//!   var result: Stat = undefined;
//!   try Stat.init(&result);
//!   ```

/// Config for no_unsafe_undefined rule.
pub const Config = struct {
    /// Severity for returning `undefined` from a function.
    return_value: zlinter.rules.LintProblemSeverity = .warning,

    /// Severity for breaking `undefined` from a block.
    break_value: zlinter.rules.LintProblemSeverity = .warning,

    /// Severity for initializing a `const` to `undefined`.
    const_value: zlinter.rules.LintProblemSeverity = .warning,

    /// Severity for initializing an optional to `undefined`.
    optional_value: zlinter.rules.LintProblemSeverity = .warning,

    /// Severity for initializing a pointer to `undefined`.
    pointer_value: zlinter.rules.LintProblemSeverity = .warning,

    /// Severity for initializing an enum or tagged union to `undefined`.
    enum_or_union_value: zlinter.rules.LintProblemSeverity = .warning,

    /// Severity for initializing a primitive scalar to `undefined`.
    primitive_scalar_value: zlinter.rules.LintProblemSeverity = .warning,
};

const Problem = enum {
    return_value,
    break_value,
    const_value,
    optional_value,
    pointer_value,
    enum_or_union_value,
    primitive_scalar_value,

    fn message(self: Problem) []const u8 {
        return switch (self) {
            .return_value => "Do not return undefined",
            .break_value => "Do not break undefined from a block",
            .const_value => "Do not initialize const values to undefined",
            .optional_value => "Use null instead of undefined for optional values",
            .pointer_value => "Do not initialize pointers to undefined",
            .enum_or_union_value => "Use a meaningful enum or union tag such as .none or .unspecified instead of undefined",
            .primitive_scalar_value => "Do not initialize primitive scalar values to undefined",
        };
    }

    fn severity(self: Problem, config: Config) zlinter.rules.LintProblemSeverity {
        return switch (self) {
            .return_value => config.return_value,
            .break_value => config.break_value,
            .const_value => config.const_value,
            .optional_value => config.optional_value,
            .pointer_value => config.pointer_value,
            .enum_or_union_value => config.enum_or_union_value,
            .primitive_scalar_value => config.primitive_scalar_value,
        };
    }
};

/// Builds and returns the no_unsafe_undefined rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_unsafe_undefined),
        .run = &run,
    };
}

/// Runs the no_unsafe_undefined rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        if (tree.nodeTag(node) != .identifier) continue :nodes;
        if (!std.mem.eql(u8, tree.getNodeSource(node), "undefined")) continue :nodes;

        const problem = try classifyUndefined(session, doc, tree, node, connections.parent) orelse continue :nodes;
        const severity = problem.severity(config);
        if (severity == .off) continue :nodes;

        try lint_problems.append(session_arena, .{
            .rule_id = rule.rule_id,
            .severity = severity,
            .start = .startOfNode(tree, node),
            .end = .endOfNode(tree, node),
            .message = try session_arena.dupe(u8, problem.message()),
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

fn classifyUndefined(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    tree: Ast,
    node: Ast.Node.Index,
    maybe_parent: ?Ast.Node.Index,
) zlinter.rules.RunError!?Problem {
    var next_parent = maybe_parent;
    while (next_parent) |parent| {
        switch (tree.nodeTag(parent)) {
            .@"return" => if (optionalNodeEquals(
                tree.nodeData(parent).opt_node,
                node,
            )) return .return_value,
            .@"break" => {
                const maybe_break_value = tree.nodeData(parent).opt_token_and_opt_node[1];
                if (optionalNodeEquals(maybe_break_value, node)) return .break_value;
            },
            else => {},
        }

        if (tree.fullVarDecl(parent)) |var_decl| {
            if (!optionalNodeEquals(var_decl.ast.init_node, node)) {
                next_parent = doc.lineage.items(.parent)[@intFromEnum(parent)];
                continue;
            }

            const type_node = var_decl.ast.type_node.unwrap() orelse {
                if (tree.tokens.items(.tag)[var_decl.ast.mut_token] == .keyword_const) return .const_value;
                return null;
            };

            if (isOptionalType(tree, type_node)) return .optional_value;
            if (isPointerType(tree, type_node)) return .pointer_value;
            if (try isEnumOrUnionType(session, doc, tree, type_node)) return .enum_or_union_value;
            if (try isPrimitiveScalarType(session, doc, tree, type_node)) return .primitive_scalar_value;

            if (tree.tokens.items(.tag)[var_decl.ast.mut_token] == .keyword_const) return .const_value;
            return null;
        }

        next_parent = doc.lineage.items(.parent)[@intFromEnum(parent)];
    }

    return null;
}

fn optionalNodeEquals(optional_node: Ast.Node.OptionalIndex, expected: Ast.Node.Index) bool {
    const node = optional_node.unwrap() orelse return false;
    return node == expected;
}

fn isOptionalType(tree: Ast, type_node: Ast.Node.Index) bool {
    var current = type_node;
    while (true) {
        switch (tree.nodeTag(current)) {
            .optional_type => return true,
            .grouped_expression => current = tree.nodeData(current).node_and_token[0],
            else => return false,
        }
    }
}

fn isPointerType(tree: Ast, type_node: Ast.Node.Index) bool {
    var current = type_node;
    while (true) {
        switch (tree.nodeTag(current)) {
            .optional_type => current = tree.nodeData(current).node,
            .grouped_expression => current = tree.nodeData(current).node_and_token[0],
            else => return tree.fullPtrType(current) != null,
        }
    }
}

fn isPrimitiveScalarType(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    tree: Ast,
    type_node: Ast.Node.Index,
) zlinter.rules.RunError!bool {
    if (directPrimitiveScalarType(tree, type_node)) return true;
    return resolvedDeclIsPrimitiveScalar(session, doc, type_node);
}

fn directPrimitiveScalarType(tree: Ast, type_node: Ast.Node.Index) bool {
    var current = type_node;
    while (true) {
        switch (tree.nodeTag(current)) {
            .grouped_expression => current = tree.nodeData(current).node_and_token[0],
            else => {
                if (tree.nodeTag(current) != .identifier) return false;
                const primitive = zlinter.session.TypeStore.primitiveFromName(
                    tree.getNodeSource(current),
                ) orelse return false;
                return switch (primitive) {
                    .bool, .number => true,
                    .named => false,
                };
            },
        }
    }
}

fn resolvedDeclIsPrimitiveScalar(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    type_node: Ast.Node.Index,
) zlinter.rules.RunError!bool {
    const candidates = try session.resolveDeclCandidatesOfNode(
        session.runtime.ruleArena(),
        doc,
        type_node,
    );
    for (candidates) |candidate| {
        const resolved = session.resolveDeclAliasCandidate(candidate);
        const decl_node = session.decl_store.declAstNode(resolved.decl_id) orelse
            continue;

        const file_id = session.decl_store.declFileId(resolved.decl_id);
        const decl_tree = session.file_store.fileTree(file_id);

        const var_decl = decl_tree.fullVarDecl(decl_node) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;

        if (directPrimitiveScalarType(decl_tree, init_node))
            return true;
    }
    return false;
}

fn isEnumOrUnionType(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    tree: Ast,
    type_node: Ast.Node.Index,
) zlinter.rules.RunError!bool {
    if (directEnumOrUnionType(tree, type_node)) return true;
    if (try resolvedDeclIsEnumOrUnion(session, doc, type_node)) return true;

    const candidates = try session.resolveValueTypeAnnotationCandidates(doc, type_node);
    for (candidates) |candidate| {
        switch (candidate.summary) {
            .instance => |instance| switch (instance.kind) {
                .@"enum", .@"union" => return true,
                else => {},
            },
            .type => |type_value| switch (type_value.kind) {
                .@"enum", .@"union" => return true,
                else => {},
            },
            else => {},
        }
    }

    return false;
}

fn resolvedDeclIsEnumOrUnion(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    type_node: Ast.Node.Index,
) zlinter.rules.RunError!bool {
    const candidates = try session.resolveDeclCandidatesOfNode(
        session.runtime.ruleArena(),
        doc,
        type_node,
    );
    for (candidates) |candidate| {
        const resolved = session.resolveDeclAliasCandidate(candidate);
        const file_id = session.decl_store.declFileId(resolved.decl_id);
        const decl_node = session.decl_store.declAstNode(resolved.decl_id) orelse continue;
        const decl_tree = session.file_store.fileTree(file_id);
        const var_decl = decl_tree.fullVarDecl(decl_node) orelse continue;
        const init_node = var_decl.ast.init_node.unwrap() orelse continue;
        if (directEnumOrUnionType(decl_tree, init_node)) return true;
    }
    return false;
}

fn directEnumOrUnionType(tree: Ast, type_node: Ast.Node.Index) bool {
    var current = type_node;
    while (true) {
        switch (tree.nodeTag(current)) {
            .optional_type => current = tree.nodeData(current).node,
            .grouped_expression => current = tree.nodeData(current).node_and_token[0],
            else => {
                var container_decl_buffer: [2]Ast.Node.Index = undefined;
                const container_decl = tree.fullContainerDecl(&container_decl_buffer, current) orelse return false;
                return switch (tree.tokens.items(.tag)[container_decl.ast.main_token]) {
                    .keyword_enum, .keyword_union => true,
                    else => false,
                };
            },
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

const isolation_test_source =
    \\const State = enum { none, ready };
    \\fn returnsUndefined() ?u32 {
    \\  return undefined;
    \\}
    \\fn breaksUndefined() State {
    \\  return blk: {
    \\    break :blk undefined;
    \\  };
    \\}
    \\const maybe: ?u32 = undefined;
    \\const state: State = undefined;
    \\const ptr: *u32 = undefined;
    \\const inferred = undefined;
    \\var scalar: u32 = undefined;
    \\fn assignsLater(flag: *bool) void {
    \\  flag.* = undefined;
    \\}
;

test "no_unsafe_undefined can enable only return_value" {
    const config: Config = .{
        .return_value = .@"error",
        .break_value = .off,
        .const_value = .off,
        .optional_value = .off,
        .pointer_value = .off,
        .enum_or_union_value = .off,
        .primitive_scalar_value = .off,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Do not return undefined" },
        },
    );
}

test "no_unsafe_undefined can enable only break_value" {
    const config: Config = .{
        .return_value = .off,
        .break_value = .@"error",
        .const_value = .off,
        .optional_value = .off,
        .pointer_value = .off,
        .enum_or_union_value = .off,
        .primitive_scalar_value = .off,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Do not break undefined from a block" },
        },
    );
}

test "no_unsafe_undefined can enable only optional_value" {
    const config: Config = .{
        .return_value = .off,
        .break_value = .off,
        .const_value = .off,
        .optional_value = .@"error",
        .pointer_value = .off,
        .enum_or_union_value = .off,
        .primitive_scalar_value = .off,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Use null instead of undefined for optional values" },
        },
    );
}

test "no_unsafe_undefined can enable only enum_or_union_value" {
    const config: Config = .{
        .return_value = .off,
        .break_value = .off,
        .const_value = .off,
        .optional_value = .off,
        .pointer_value = .off,
        .enum_or_union_value = .@"error",
        .primitive_scalar_value = .off,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Use a meaningful enum or union tag such as .none or .unspecified instead of undefined" },
        },
    );
}

test "no_unsafe_undefined can enable only pointer_value" {
    const config: Config = .{
        .return_value = .off,
        .break_value = .off,
        .const_value = .off,
        .optional_value = .off,
        .pointer_value = .@"error",
        .enum_or_union_value = .off,
        .primitive_scalar_value = .off,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Do not initialize pointers to undefined" },
        },
    );
}

test "no_unsafe_undefined can enable only const_value" {
    const config: Config = .{
        .return_value = .off,
        .break_value = .off,
        .const_value = .@"error",
        .optional_value = .off,
        .pointer_value = .off,
        .enum_or_union_value = .off,
        .primitive_scalar_value = .off,
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Do not initialize const values to undefined" },
        },
    );
}

test "no_unsafe_undefined can enable only primitive_scalar_value" {
    const config: Config = .{
        .return_value = .off,
        .break_value = .off,
        .const_value = .off,
        .optional_value = .off,
        .pointer_value = .off,
        .enum_or_union_value = .off,
        .primitive_scalar_value = .@"error",
    };

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        isolation_test_source,
        .{},
        config,
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .@"error", .slice = "undefined", .message = "Do not initialize primitive scalar values to undefined" },
        },
    );
}

test "no_unsafe_undefined reports returning undefined from a function" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn returnsUndefined() ?u32 {
        \\  return undefined;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not return undefined" },
        },
    );
}

test "no_unsafe_undefined reports breaking undefined from a block" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn breaksUndefined() u32 {
        \\  return blk: {
        \\    break :blk undefined;
        \\  };
        \\}
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not break undefined from a block" },
        },
    );
}

test "no_unsafe_undefined reports optional initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const maybe: ?u32 = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Use null instead of undefined for optional values" },
        },
    );
}

test "no_unsafe_undefined reports enum initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const State = enum { none, ready };
        \\const state: State = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Use a meaningful enum or union tag such as .none or .unspecified instead of undefined" },
        },
    );
}

test "no_unsafe_undefined reports tagged union initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const Payload = union(enum) { none, text: []const u8 };
        \\const payload: Payload = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Use a meaningful enum or union tag such as .none or .unspecified instead of undefined" },
        },
    );
}

test "no_unsafe_undefined reports const initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const inferred = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize const values to undefined" },
        },
    );
}

test "no_unsafe_undefined reports pointer initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const ptr: *u32 = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize pointers to undefined" },
        },
    );
}

test "no_unsafe_undefined reports primitive scalar initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\var flag: bool = undefined;
        \\var count: u32 = undefined;
        \\var ratio: f64 = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize primitive scalar values to undefined" },
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize primitive scalar values to undefined" },
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize primitive scalar values to undefined" },
        },
    );
}

test "no_unsafe_undefined reports primitive scalar aliases initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const Flag = bool;
        \\const Count = u32;
        \\var flag: Flag = undefined;
        \\var count: Count = undefined;
    ,
        .{},
        Config{},
        &.{
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize primitive scalar values to undefined" },
            .{ .rule_id = "no_unsafe_undefined", .severity = .warning, .slice = "undefined", .message = "Do not initialize primitive scalar values to undefined" },
        },
    );
}

test "no_unsafe_undefined allows scratch buffer initialized to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\var buffer: [1024]u8 = undefined;
    ,
        .{},
        Config{},
        &.{},
    );
}

test "no_unsafe_undefined allows later assignment to undefined" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn deinit(flag: *bool) void {
        \\  flag.* = undefined;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "no_unsafe_undefined allows explicit optional sentinel values" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\fn returnsNull() ?u32 {
        \\  return null;
        \\}
        \\const maybe: ?u32 = null;
        \\const ptr: ?*u32 = null;
    ,
        .{},
        Config{},
        &.{},
    );
}

test "no_unsafe_undefined allows meaningful enum and tagged union tags" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const State = enum { none, ready, unspecified };
        \\const Payload = union(enum) { none, text: []const u8 };
        \\fn breaksTag() State {
        \\  return blk: {
        \\    break :blk .unspecified;
        \\  };
        \\}
        \\const state: State = .none;
        \\const payload: Payload = .none;
    ,
        .{},
        Config{},
        &.{},
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
