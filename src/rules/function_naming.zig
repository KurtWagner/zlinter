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
    function: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .camel_case },

    /// Style and severity for type functions
    function_that_returns_type: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Style and severity for standard function arg
    function_arg: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Style and severity for type function arg
    function_arg_that_is_type: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },

    /// Style and severity for non-type function function arg
    function_arg_that_is_fn: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .camel_case },

    /// Style and severity for type function function arg
    function_arg_that_is_type_fn: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },
};

const ParamKind = struct {
    name: []const u8,
    kind: zlinter.session.TypeStore.TypeSummary,
};

/// Builds and returns the function_naming rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.function_naming),
        .run = &run,
    };
}

/// Runs the function_naming rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const zone = zlinter.tracy.traceNamed(@src(), "rule.function_naming");
    defer zone.end();
    zone.addText(doc.absPath(session));

    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;

    const tree = doc.tree(session);

    var index: u32 = 1; // Skip root node at 0
    nodes: while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        var buffer: [1]Ast.Node.Index = undefined;
        if (namedFnProto(tree, &buffer, node)) |fn_proto| {
            if (shouldSkipFnProto(tree, fn_proto, config)) continue :nodes;

            const fn_name_token = fn_proto.name_token.?;
            const fn_name = zlinter.strings.normalizeIdentifierName(tree.tokenSlice(fn_name_token));

            const return_type = classifyReturnType(
                session,
                doc,
                tree,
                fn_proto,
            ) orelse continue :nodes;

            const error_message: ?[]const u8, const severity: ?zlinter.rules.LintProblemSeverity = msg: {
                if (functionReturnsType(return_type)) {
                    const style = config.function_that_returns_type.style() orelse break :msg .{ null, null };
                    if (!style.check(fn_name))
                        break :msg .{
                            try session_arena.print("Callable returning `type` should be {s}", .{style.name()}),
                            config.function_that_returns_type.severity(),
                        };
                } else {
                    const style = config.function.style() orelse break :msg .{ null, null };
                    if (!style.check(fn_name))
                        break :msg .{
                            try session_arena.print("Callable should be {s}", .{style.name()}),
                            config.function.severity(),
                        };
                }
                break :msg .{ null, null };
            };

            if (error_message) |message|
                try lint_problems.append(
                    session_arena,
                    .{
                        .severity = severity.?,
                        .rule_id = rule.rule_id,
                        .start = .startOfToken(tree, fn_name_token),
                        .end = .endOfToken(tree, fn_name_token),
                        .message = message,
                    },
                );
        }

        // Check arguments:
        if (fnProto(tree, &buffer, node)) |fn_proto| {
            if (shouldSkipFnProto(tree, fn_proto, config)) continue :nodes;

            var param_kinds = std.ArrayList(ParamKind).empty;

            // Anonymous and nested fn prototypes are intentionally checked so
            // callback/function-type parameter names follow the same rules.
            params: for (fn_proto.ast.params) |param| {
                const colon_token = tree.firstToken(param) - 1;
                if (tree.tokens.items(.tag)[colon_token] != .colon) continue :params;

                const identifer_token = colon_token - 1;
                if (tree.tokens.items(.tag)[identifer_token] != .identifier)
                    continue :params;
                const identifier = tree.tokenSlice(identifer_token);

                if (identifier.len == 1 and identifier[0] == '_') continue :params;

                const type_classifications = try classifyParamTypeCandidates(
                    session,
                    doc,
                    tree,
                    param,
                    param_kinds.items,
                );

                for (type_classifications) |classification|
                    switch (classification.summary) {
                        .@"fn", .fn_returns_type => try param_kinds.append(rule_arena, .{
                            .name = identifier,
                            .kind = classification.summary,
                        }),
                        .type => |type_value| switch (type_value.kind) {
                            .@"fn", .fn_returns_type => try param_kinds.append(rule_arena, .{
                                .name = identifier,
                                .kind = classification.summary,
                            }),
                            else => {},
                        },
                        else => {},
                    };

                classifications: for (type_classifications) |classification| {
                    const style_with_severity: zlinter.rules.LintTextStyleWithSeverity, const desc: []const u8 = style: {
                        break :style switch (classification.summary) {
                            .@"fn" => .{ config.function_arg_that_is_fn, "Function argument of function" },
                            .fn_returns_type => .{ config.function_arg_that_is_type_fn, "Function argument of type function" },
                            .type => |type_value| switch (type_value.kind) {
                                .@"fn" => .{ config.function_arg_that_is_fn, "Function argument of function" },
                                .fn_returns_type => .{ config.function_arg_that_is_type_fn, "Function argument of type function" },
                                else => .{ config.function_arg_that_is_type, "Function argument of type" },
                            },
                            else => .{ config.function_arg, "Function argument" },
                        };
                    };

                    const style = style_with_severity.style() orelse continue :classifications;
                    if (style.check(identifier)) continue :classifications;

                    try lint_problems.append(session_arena, .{
                        .rule_id = rule.rule_id,
                        .severity = style_with_severity.severity(),
                        .start = .startOfToken(tree, identifer_token),
                        .end = .endOfToken(tree, identifer_token),
                        .message = try session_arena.print("{s} should be {s}", .{ desc, style.name() }),
                        .notes = try allocResolvedDeclNotes(
                            session_arena,
                            session,
                            classification.source_decl_id,
                        ),
                    });
                }
            }
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

fn shouldSkipFnProto(tree: Ast, fn_proto: Ast.full.FnProto, config: Config) bool {
    const token = fn_proto.extern_export_inline_token orelse
        return false;

    const tag = tree.tokens.items(.tag)[token];
    return (config.exclude_extern and tag == .keyword_extern) or
        (config.exclude_export and tag == .keyword_export);
}

fn classifyReturnType(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    tree: Ast,
    fn_proto: Ast.full.FnProto,
) ?zlinter.session.TypeStore.TypeSummary {
    const return_type_node = fn_proto.ast.return_type.unwrap() orelse return null;
    const payload_node = unwrapErrorUnionPayloadTypeNode(tree, return_type_node);

    const type_candidates = session.resolveValueTypeAnnotationCandidates(
        doc,
        payload_node,
    ) catch return null;
    for (type_candidates) |candidate|
        if (functionReturnsType(candidate.summary)) return candidate.summary;
    return type_candidates[0].summary;
}

fn unwrapErrorUnionPayloadTypeNode(tree: Ast, node: Ast.Node.Index) Ast.Node.Index {
    const unwrapped_node = zlinter.ast.unwrapNode(tree, node, .{});
    if (tree.nodeTag(unwrapped_node) != .error_union) return unwrapped_node;
    return tree.nodeData(unwrapped_node).node_and_node[1];
}

fn functionReturnsType(return_type: zlinter.session.TypeStore.TypeSummary) bool {
    return switch (return_type) {
        .type => |type_value| type_value.kind == .unknown,
        else => false,
    };
}

fn classifyParamTypeCandidates(
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    tree: Ast,
    param: Ast.Node.Index,
    seen_param_kinds: []const ParamKind,
) ![]const zlinter.session.LintSession.ValueTypeAnnotationCandidate {
    const param_type_node = zlinter.ast.unwrapNode(
        tree,
        param,
        .{},
    );

    const maybe_type_name = if (tree.nodeTag(param_type_node) == .identifier)
        tree.getNodeSource(param_type_node)
    else
        null;

    if (maybe_type_name) |type_name|
        for (seen_param_kinds) |param_kind|
            if (std.mem.eql(u8, param_kind.name, type_name)) {
                var candidates = std.ArrayList(
                    zlinter.session.LintSession.ValueTypeAnnotationCandidate,
                ).empty;
                try candidates.append(session.runtime.ruleArena(), .{
                    .summary = switch (param_kind.kind) {
                        .type => |type_value| switch (type_value.kind) {
                            .@"fn" => .@"fn",
                            .fn_returns_type => .fn_returns_type,
                            else => param_kind.kind,
                        },
                        else => param_kind.kind,
                    },
                });
                return candidates.items;
            };

    const candidates = try session.resolveValueTypeAnnotationCandidates(
        doc,
        param_type_node,
    );
    return candidates;
}

fn allocResolvedDeclNotes(
    session_arena: std.mem.Allocator,
    session: *zlinter.session.LintSession,
    maybe_decl_id: ?zlinter.session.DeclStore.DeclId,
) !?[]zlinter.results.LintProblemNote {
    const decl_id = maybe_decl_id orelse return null;
    const decl_location = session.declLocation(decl_id) orelse return null;

    const notes = try session_arena.alloc(
        zlinter.results.LintProblemNote,
        1,
    );
    notes[0] = .{
        .file_id = decl_location.file_id,
        .start = decl_location.start,
        .end = decl_location.end,
        .line = decl_location.line,
        .column = decl_location.column,
        .message = try session_arena.dupe(u8, "resolved declaration is here"),
    };
    return notes;
}

/// Returns fn proto if node is fn proto and has a name token.
fn namedFnProto(tree: Ast, buffer: *[1]Ast.Node.Index, node: Ast.Node.Index) ?Ast.full.FnProto {
    if (fnProto(tree, buffer, node)) |fn_proto|
        if (fn_proto.name_token != null) return fn_proto;
    return null;
}

/// Returns fn proto if node is fn proto and has a name token.
fn fnProto(tree: Ast, buffer: *[1]Ast.Node.Index, node: Ast.Node.Index) ?Ast.full.FnProto {
    if (switch (tree.nodeTag(node)) {
        .fn_proto => tree.fnProto(node),
        .fn_proto_multi => tree.fnProtoMulti(node),
        .fn_proto_one => tree.fnProtoOne(buffer, node),
        .fn_proto_simple => tree.fnProtoSimple(buffer, node),
        else => null,
    }) |fn_proto|
        return fn_proto;
    return null;
}

test {
    std.testing.refAllDecls(@This());
}

test "export excluded" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\export fn export_not_good() void;
        \\export fn exportNotGood() void;
        \\export fn exportWith(BadArg: u32) void;
    ,
        .{},
        Config{ .exclude_export = true },
        &.{},
    );
}

test "export included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\export fn export_not_good() void;
        \\export fn exportGood() void;
        \\export fn exportWith(BadArg: u32) void;
    ,
        .{},
        Config{ .exclude_export = false },
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "export_not_good",
                .message = "Callable should be camelCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadArg",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "extern excluded" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\extern fn extern_not_good() void;
        \\extern fn ExternNotGood() void;
        \\extern fn externWith(BadArg: u32) void;
    ,
        .{},
        Config{ .exclude_extern = true },
        &.{},
    );
}

test "extern included" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\extern fn extern_not_good() void;
        \\extern fn externGood() void;
        \\extern fn externWith(BadArg: u32) void;
    ,
        .{},
        Config{ .exclude_extern = false },
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "extern_not_good",
                .message = "Callable should be camelCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadArg",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "general" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
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
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "not_good",
                .message = "Callable should be camelCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "NotGood",
                .message = "Callable should be camelCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "Arg",
                .message = "Function argument should be snake_case",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "t",
                .message = "Function argument of type should be TitleCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "fn_call",
                .message = "Function argument of function should be camelCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "A",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "function parameters named after value instances remain snake_case" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const Ast = struct {
        \\    const Node = struct {
        \\        const Index = u32;
        \\    };
        \\};
        \\const Thing = struct {};
        \\
        \\fn takesNamedTypes(tree: Ast, node: Ast.Node.Index, thing: Thing) void {
        \\    _ = tree;
        \\    _ = node;
        \\    _ = thing;
        \\}
        \\
        \\fn takesGeneric(T: type, value: T, BadValue: T) void {
        \\    _ = T;
        \\    _ = value;
        \\    _ = BadValue;
        \\}
        \\
        \\fn takesTypes(GoodType: type, bad_type: type) void {
        \\    _ = GoodType;
        \\    _ = bad_type;
        \\}
        \\
        \\fn takesFunctions(goodFn: *const fn () void, bad_fn: *const fn () void) void {
        \\    _ = goodFn;
        \\    _ = bad_fn;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadValue",
                .message = "Function argument should be snake_case",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "bad_type",
                .message = "Function argument of type should be TitleCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "bad_fn",
                .message = "Function argument of function should be camelCase",
            },
        },
    );
}

test "generic value parameters remain normal value parameters after resolver lookup" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\fn takesGeneric(T: type, value: T, BadValue: T) void {
        \\    _ = T;
        \\    _ = value;
        \\    _ = BadValue;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadValue",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "unresolved parameter type resolution falls back without notes" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\fn takesUnresolved(BadValue: Missing.Type, anotherBadValue: Missing) void {
        \\    _ = BadValue;
        \\    _ = anotherBadValue;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadValue",
                .message = "Function argument should be snake_case",
                .notes = &.{},
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "anotherBadValue",
                .message = "Function argument should be snake_case",
                .notes = &.{},
            },
        },
    );
}

test "unknown and opaque aliases used as value parameter types remain snake_case" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const value: u32 = 1;
        \\const UnknownAlias = @TypeOf(value);
        \\const OpaqueAlias = opaque {};
        \\
        \\fn takesUnknownAlias(good_value: UnknownAlias, badValue: UnknownAlias) void {
        \\    _ = good_value;
        \\    _ = badValue;
        \\}
        \\
        \\fn takesOpaqueAlias(good_value: OpaqueAlias, BadValue: OpaqueAlias) void {
        \\    _ = good_value;
        \\    _ = BadValue;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "badValue",
                .message = "Function argument should be snake_case",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadValue",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "aliased return type annotations are treated as returning type" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const ReturnsType = type;
        \\
        \\fn bad_name() ReturnsType {
        \\    return u32;
        \\}
        \\
        \\fn GoodName() ReturnsType {
        \\    return u32;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "bad_name",
                .message = "Callable returning `type` should be TitleCase",
            },
        },
    );
}

test "namespaced aliased return type annotations are treated as returning type" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const ns = struct {
        \\    const ReturnsType = type;
        \\};
        \\
        \\fn bad_name() ns.ReturnsType {
        \\    return u32;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "bad_name",
                .message = "Callable returning `type` should be TitleCase",
            },
        },
    );
}

test "ordinary return aliases are not treated as returning type" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const ReturnValue = u32;
        \\const Thing = struct {};
        \\
        \\fn goodName() ReturnValue {
        \\    return 1;
        \\}
        \\
        \\fn alsoGood() Thing {
        \\    return .{};
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "FnType suffix does not classify ordinary aliases as type functions" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\const NotReallyFnType = u32;
        \\
        \\fn takesValue(good_value: NotReallyFnType, badValue: NotReallyFnType) void {
        \\    _ = good_value;
        \\    _ = badValue;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "badValue",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "nested function prototype parameters are linted" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\fn takesCallback(callback: *const fn (BadArg: u32) void) void {
        \\    _ = callback;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "BadArg",
                .message = "Function argument should be snake_case",
            },
        },
    );
}

test "extern and export skips apply to function names and parameters" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\extern fn extern_not_good(BadArg: u32) void;
        \\export fn export_not_good(BadArg: u32) void;
    ,
        .{},
        Config{ .exclude_extern = true, .exclude_export = true },
        &.{},
    );
}

test "function returning error set is not treated as returning type" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\fn logAndReturnWriteFailure(comptime suffix: []const u8, err: anyerror) error{WriteFailure} {
        \\    _ = suffix;
        \\    _ = err;
        \\    return error.WriteFailure;
        \\}
    ,
        .{},
        Config{},
        &.{},
    );
}

test "fallible functions returning type are treated as returning type" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\
        \\fn Bad_name() !type {
        \\    return u32;
        \\}
        \\
        \\fn bad_name() error{Oops}!type {
        \\    return u32;
        \\}
        \\
        \\fn badError() !void {
        \\    return error.Oops;
        \\}
        \\
        \\fn alsoBadError() error{Oops}!void {
        \\    return error.Oops;
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "Bad_name",
                .message = "Callable returning `type` should be TitleCase",
            },
            .{
                .rule_id = "function_naming",
                .severity = .@"error",
                .slice = "bad_name",
                .message = "Callable returning `type` should be TitleCase",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
