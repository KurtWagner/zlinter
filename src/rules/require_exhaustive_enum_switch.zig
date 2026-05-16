//! Require explicit exhaustiveness for switches over exhaustive enums.
//!
//! This rule ensures switches over exhaustive enums remain explicit as the code evolves.
//! When a new enum tag is introduced, a switch that uses `else` can continue compiling while
//! unintentionally routing the new value through unintended logic. This hides missing behavior and
//! makes such changes easy to overlook during testing and review.
//!
//! Requiring every tag to be listed forces the author to decide how each value should be handled.
//! This keeps control flow intentional, improves readability, and prevents silently mis-handling
//! newly added enum values.
//!
//! **Good:**
//!
//! ```zig
//! const State = enum { idle, running, stopped };
//! fn handle(state: State) void {
//!     switch (state) {
//!         .idle => {},
//!         .running => {},
//!         .stopped => {},
//!     }
//! }
//! ```
//!
//! **Bad (else on exhaustive enum):**
//!
//! ```zig
//! const State = enum { idle, running, stopped };
//! fn handle(state: State) void {
//!     switch (state) {
//!         .idle => {},
//!         .running => {},
//!         else => {},
//!     }
//! }
//! ```

/// Config for require_exhaustive_enum_switch rule.
pub const Config = struct {
    /// The severity (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the require_exhaustive_enum_switch rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.require_exhaustive_enum_switch),
        .run = &run,
    };
}

/// Runs the require_exhaustive_enum_switch rule.
fn run(
    rule: zlinter.rules.LintRule,
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    _ = context;
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    const tree = doc.handle.tree;

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, gpa);
    defer it.deinit();

    // Holds all tags within an enum used in a switch statement
    var complete_tag_set: std.StringHashMap(void) = .init(gpa);
    defer complete_tag_set.deinit();

    // Tracks only the used enum tags within a switch statement
    var used_tag_set = std.StringHashMap(void).init(gpa);
    defer used_tag_set.deinit();

    var missing_tags: std.ArrayList([]const u8) = .empty;
    defer missing_tags.deinit(gpa);

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;
        _ = connections;

        const switch_info = tree.fullSwitch(node) orelse continue :nodes;

        const switch_offset = tree.tokenStart(tree.firstToken(node));
        var switch_expr_enum = try enumInfoFromExpr(
            doc,
            switch_info.ast.condition,
            switch_offset,
            gpa,
            0,
        ) orelse continue :nodes;
        defer switch_expr_enum.deinit(gpa);

        if (switch_expr_enum.is_non_exhaustive) continue :nodes;
        if (switch_expr_enum.tags.len == 0) continue :nodes;

        defer complete_tag_set.clearRetainingCapacity();
        try complete_tag_set.ensureTotalCapacity(@intCast(switch_expr_enum.tags.len));
        for (switch_expr_enum.tags) |tag| {
            complete_tag_set.putAssumeCapacity(tag, {});
        }

        // Set if an else case exists in switch
        var else_case_node: ?Ast.Node.Index = null;

        defer used_tag_set.clearRetainingCapacity();
        for (switch_info.ast.cases) |case_node| {
            const switch_case = tree.fullSwitchCase(case_node).?;

            if (switch_case.ast.values.len == 0) {
                if (else_case_node == null) else_case_node = case_node;
            } else {
                case_values: for (switch_case.ast.values) |value_node| {
                    const tag_name = try tagNameFromSwitchCaseValue(
                        tree,
                        value_node,
                        switch_offset,
                    ) orelse continue :case_values;

                    if (complete_tag_set.contains(tag_name))
                        try used_tag_set.put(tag_name, {});
                }
            }
        }

        if (else_case_node != null) {
            missing_tags.clearRetainingCapacity();

            for (switch_expr_enum.tags) |tag| {
                if (!used_tag_set.contains(tag)) {
                    try missing_tags.append(gpa, tag);
                }
            }

            try lint_problems.append(gpa, .{
                .rule_id = rule.rule_id,
                .severity = config.severity,
                .start = .startOfToken(tree, tree.firstToken(node)),
                .end = .endOfToken(tree, tree.firstToken(node)),
                .message = buildProblemMessage(missing_tags.items, gpa) catch "Error building linter message",
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            gpa,
            doc.path,
            try lint_problems.toOwnedSlice(gpa),
        )
    else
        null;
}

fn tagNameFromSwitchCaseValue(
    tree: Ast,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
) error{OutOfMemory}!?[]const u8 {
    return switch (tree.nodeTag(node)) {
        // e.g., `.a`
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(node)),
        // e.g., `a` where `a = MyEnum.a`
        .identifier => try tagNameForIdentifier(tree, node, before_offset),
        // e.g., `MyEnum.a`
        .field_access => blk: {
            const last_token = tree.lastToken(node);
            if (tree.tokenTag(last_token) != .identifier) break :blk null;
            break :blk tree.tokenSlice(last_token);
        },
        else => {
            std.log.err(
                "require_exhaustive_enum_switch: unhandled switch case value node tag: {t}",
                .{tree.nodeTag(node)},
            );
            return null;
        },
    } orelse null;
}

fn tagNameForIdentifier(
    tree: Ast,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
) error{OutOfMemory}!?[]const u8 {
    const token = tree.nodeMainToken(node);
    std.debug.assert(tree.tokenTag(token) == .identifier);

    const name = tree.tokenSlice(token);
    const var_decl = findVarDeclByNameNear(tree, name, before_offset) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const unwrapped = zlinter.ast.unwrapNode(tree, init_node, .{
        .unwrap_optional_unwrap = false,
    });

    if (tree.nodeTag(unwrapped) == .enum_literal) {
        return tree.tokenSlice(tree.nodeMainToken(unwrapped));
    }
    if (tree.nodeTag(unwrapped) == .field_access) {
        const last_token = tree.lastToken(unwrapped);
        if (tree.tokenTag(last_token) == .identifier) {
            return tree.tokenSlice(last_token);
        }
    }

    return null;
}

const EnumInfoLite = struct {
    tags: []const []const u8,
    is_non_exhaustive: bool,

    pub fn deinit(self: *EnumInfoLite, gpa: std.mem.Allocator) void {
        gpa.free(self.tags);
        self.* = undefined;
    }
};

fn enumInfoFromExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    gpa: std.mem.Allocator,
    depth: u8,
) !?EnumInfoLite {
    const tree = doc.handle.tree;
    if (depth > 12) return null;

    if (try enumInfoFromKnownCallExpr(doc, node, before_offset, gpa, depth + 1)) |enum_info| {
        return enum_info;
    }

    if (resolveEnumContainerNodeFromExpr(doc, node, before_offset, depth)) |enum_container_node| {
        return enumInfoFromContainerNode(tree, enum_container_node, gpa);
    }

    return null;
}

fn enumInfoFromKnownCallExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    gpa: std.mem.Allocator,
    depth: u8,
) !?EnumInfoLite {
    const tree = doc.handle.tree;
    if (depth > 12) return null;

    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&call_buffer, node) orelse return null;
    const fn_expr = call.ast.fn_expr;

    switch (tree.nodeTag(fn_expr)) {
        .identifier => {
            const fn_name = tree.getNodeSource(fn_expr);
            const fn_decl = findFnDeclByNameNear(tree, fn_name, before_offset) orelse return null;
            const return_type_node = fn_decl.ast.return_type.unwrap() orelse return null;

            if (try enumInfoFromKnownTypeExpr(doc, return_type_node, before_offset, gpa, depth + 1)) |known| {
                return known;
            }

            if (resolveEnumContainerNodeFromTypeExpr(doc, return_type_node, before_offset, depth + 1)) |enum_node| {
                return enumInfoFromContainerNode(tree, enum_node, gpa);
            }

            return null;
        },
        .field_access => {
            const data = tree.nodeData(fn_expr).node_and_token;
            const lhs = data.@"0";
            const method_token = data.@"1";
            if (tree.tokenTag(method_token) != .identifier) return null;

            const method_name = tree.tokenSlice(method_token);
            if (std.mem.eql(u8, method_name, "nodeTag") and
                isStdAstValueExpr(doc, lhs, before_offset, depth + 1))
            {
                return enumInfoFromComptimeEnum(Ast.Node.Tag, gpa);
            }
            if (std.mem.eql(u8, method_name, "tokenTag") and
                isStdAstValueExpr(doc, lhs, before_offset, depth + 1))
            {
                return enumInfoFromComptimeEnum(std.zig.Token.Tag, gpa);
            }

            return null;
        },
        else => return null,
    }
}

fn enumInfoFromKnownTypeExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    gpa: std.mem.Allocator,
    depth: u8,
) !?EnumInfoLite {
    if (depth > 12) return null;

    if (isStdAstNodeTagTypeExpr(doc, node, before_offset, depth + 1)) {
        return enumInfoFromComptimeEnum(Ast.Node.Tag, gpa);
    }
    if (isStdAstTokenTagTypeExpr(doc, node, before_offset, depth + 1)) {
        return enumInfoFromComptimeEnum(std.zig.Token.Tag, gpa);
    }

    return null;
}

fn enumInfoFromComptimeEnum(comptime T: type, gpa: std.mem.Allocator) !?EnumInfoLite {
    const fields = std.meta.fields(T);
    var tags = try gpa.alloc([]const u8, fields.len);
    inline for (fields, 0..) |field, i| {
        tags[i] = field.name;
    }
    return .{
        .tags = tags,
        .is_non_exhaustive = false,
    };
}

fn isStdAstValueExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            const ident_name = tree.getNodeSource(unwrapped);

            if (resolveParamTypeNode(doc, unwrapped, ident_name)) |type_node| {
                if (isStdAstTypeExpr(doc, type_node, before_offset, depth + 1)) return true;
            }

            const var_decl = findVarDeclByNameNear(tree, ident_name, before_offset) orelse return false;
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                if (isStdAstTypeExpr(doc, type_node, before_offset, depth + 1)) return true;
            }
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (isStdAstTypeExpr(doc, init_node, before_offset, depth + 1)) return true;
            }

            return false;
        },
        else => return false,
    }
}

fn isStdAstTypeExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });

    if (isStdZigAstPath(doc, unwrapped, before_offset, depth + 1)) return true;

    if (tree.nodeTag(unwrapped) == .identifier) {
        const ident_name = tree.getNodeSource(unwrapped);
        const var_decl = findVarDeclByNameNear(tree, ident_name, before_offset) orelse return false;
        const init_node = var_decl.ast.init_node.unwrap() orelse return false;
        return isStdZigAstPath(doc, init_node, before_offset, depth + 1);
    }

    return false;
}

fn isStdAstNodeTagTypeExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    return isStdAstNestedType(doc, node, before_offset, depth, "Node", "Tag");
}

fn isStdAstTokenTagTypeExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    return isStdAstNestedType(doc, node, before_offset, depth, "Token", "Tag");
}

fn isStdAstNestedType(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
    mid_field: []const u8,
    leaf_field: []const u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    if (tree.nodeTag(unwrapped) != .field_access) return false;

    const data = tree.nodeData(unwrapped).node_and_token;
    const lhs = data.@"0";
    const leaf_token = data.@"1";
    if (tree.tokenTag(leaf_token) != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(leaf_token), leaf_field)) return false;

    const lhs_unwrapped = zlinter.ast.unwrapNode(tree, lhs, .{
        .unwrap_optional_unwrap = false,
    });
    if (tree.nodeTag(lhs_unwrapped) != .field_access) return false;

    const lhs_data = tree.nodeData(lhs_unwrapped).node_and_token;
    const ast_base = lhs_data.@"0";
    const mid_token = lhs_data.@"1";
    if (tree.tokenTag(mid_token) != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(mid_token), mid_field)) return false;

    return isStdAstTypeExpr(doc, ast_base, before_offset, depth + 1);
}

fn isStdZigAstPath(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });

    if (tree.nodeTag(unwrapped) != .field_access) return false;
    const data = tree.nodeData(unwrapped).node_and_token;
    const lhs = data.@"0";
    const field_token = data.@"1";
    if (tree.tokenTag(field_token) != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(field_token), "Ast")) return false;

    const lhs_unwrapped = zlinter.ast.unwrapNode(tree, lhs, .{
        .unwrap_optional_unwrap = false,
    });
    if (tree.nodeTag(lhs_unwrapped) != .field_access) return false;

    const lhs_data = tree.nodeData(lhs_unwrapped).node_and_token;
    const std_expr = lhs_data.@"0";
    const zig_token = lhs_data.@"1";
    if (tree.tokenTag(zig_token) != .identifier) return false;
    if (!std.mem.eql(u8, tree.tokenSlice(zig_token), "zig")) return false;

    return isStdImportExpr(doc, std_expr, before_offset, depth + 1);
}

fn isStdImportExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) bool {
    const tree = doc.handle.tree;
    if (depth > 12) return false;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });
    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            const ident_name = tree.getNodeSource(unwrapped);
            const var_decl = findVarDeclByNameNear(tree, ident_name, before_offset) orelse return false;
            const init_node = var_decl.ast.init_node.unwrap() orelse return false;
            return isStdImportExpr(doc, init_node, before_offset, depth + 1);
        },
        .builtin_call_two,
        .builtin_call_two_comma,
        => {
            const main_token = tree.nodeMainToken(unwrapped);
            if (!std.mem.eql(u8, "@import", tree.tokenSlice(main_token))) return false;

            const data = tree.nodeData(unwrapped);
            const arg_node = data.opt_node_and_opt_node[0].unwrap() orelse return false;
            if (tree.nodeTag(arg_node) != .string_literal) return false;

            const import_slice = tree.tokenSlice(tree.nodeMainToken(arg_node));
            return import_slice.len >= 2 and std.mem.eql(u8, import_slice[1 .. import_slice.len - 1], "std");
        },
        else => return false,
    }
}

fn resolveEnumContainerNodeFromExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?Ast.Node.Index {
    const tree = doc.handle.tree;
    if (depth > 12) return null;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
        .unwrap_optional_unwrap = false,
    });

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, unwrapped)) |container_decl| {
        if (tree.tokens.items(.tag)[container_decl.ast.main_token] == .keyword_enum) {
            return unwrapped;
        }
    }

    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            if (resolveEnumContainerFromIdentifier(doc, unwrapped, before_offset, depth + 1)) |enum_container| {
                return enum_container;
            }
            return null;
        },
        .field_access => {
            const lhs = tree.nodeData(unwrapped).node_and_token.@"0";
            return resolveEnumContainerNodeFromTypeExpr(doc, lhs, before_offset, depth + 1);
        },
        .enum_literal => return null,
        else => return null,
    }
}

fn resolveEnumContainerNodeFromTypeExpr(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?Ast.Node.Index {
    const tree = doc.handle.tree;
    if (depth > 12) return null;

    const unwrapped = zlinter.ast.unwrapNode(tree, node, .{});

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, unwrapped)) |container_decl| {
        if (tree.tokens.items(.tag)[container_decl.ast.main_token] == .keyword_enum) {
            return unwrapped;
        }
    }

    switch (tree.nodeTag(unwrapped)) {
        .identifier => {
            if (resolveEnumContainerFromIdentifier(doc, unwrapped, before_offset, depth + 1)) |enum_container| {
                return enum_container;
            }
            return null;
        },
        .field_access => {
            const lhs = tree.nodeData(unwrapped).node_and_token.@"0";
            return resolveEnumContainerNodeFromTypeExpr(doc, lhs, before_offset, depth + 1);
        },
        else => return null,
    }
}

fn resolveEnumContainerFromIdentifier(
    doc: *const zlinter.session.LintDocument,
    identifier_node: Ast.Node.Index,
    before_offset: Ast.ByteOffset,
    depth: u8,
) ?Ast.Node.Index {
    const tree = doc.handle.tree;
    if (depth > 12) return null;

    const ident_name = tree.getNodeSource(identifier_node);

    if (resolveParamTypeNode(doc, identifier_node, ident_name)) |type_node| {
        if (resolveEnumContainerNodeFromTypeExpr(doc, type_node, before_offset, depth + 1)) |enum_container| {
            return enum_container;
        }
    }

    const var_decl = findVarDeclByNameNear(tree, ident_name, before_offset) orelse return null;

    if (var_decl.ast.type_node.unwrap()) |type_node| {
        if (resolveEnumContainerNodeFromTypeExpr(doc, type_node, before_offset, depth + 1)) |enum_container| {
            return enum_container;
        }
    }

    if (var_decl.ast.init_node.unwrap()) |init_node| {
        if (resolveEnumContainerNodeFromExpr(doc, init_node, before_offset, depth + 1)) |enum_container| {
            return enum_container;
        }
    }

    return null;
}

fn resolveParamTypeNode(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    param_name: []const u8,
) ?Ast.Node.Index {
    const tree = doc.handle.tree;
    var current = node;

    while (doc.lineage.items(.parent)[@intFromEnum(current)]) |parent| {
        current = parent;
        if (tree.nodeTag(current) != .fn_decl) continue;

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        const fn_decl = zlinter.ast.fnDecl(tree, current, &fn_proto_buffer) orelse continue;
        var param_it = fn_decl.proto.iterate(&tree);
        while (param_it.next()) |param| {
            const name_token = param.name_token orelse continue;
            if (!std.mem.eql(u8, tree.tokenSlice(name_token), param_name)) continue;
            return param.type_expr;
        }
        return null;
    }

    return null;
}

fn enumInfoFromContainerNode(
    tree: Ast,
    enum_node: Ast.Node.Index,
    gpa: std.mem.Allocator,
) !?EnumInfoLite {
    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    const container_decl = tree.fullContainerDecl(&container_decl_buffer, enum_node) orelse return null;
    if (tree.tokens.items(.tag)[container_decl.ast.main_token] != .keyword_enum) return null;

    var tags: std.ArrayList([]const u8) = try .initCapacity(gpa, container_decl.ast.members.len);
    errdefer tags.deinit(gpa);

    for (container_decl.ast.members) |member| {
        const tag_name_token = switch (tree.nodeTag(member)) {
            .container_field_init,
            .container_field_align,
            .container_field,
            => tree.nodeMainToken(member),
            else => continue,
        };
        tags.appendAssumeCapacity(tree.tokenSlice(tag_name_token));
    }

    var is_non_exhaustive = false;
    if (tags.items.len > 0 and std.mem.eql(u8, tags.items[tags.items.len - 1], "_")) {
        is_non_exhaustive = true;
        _ = tags.pop();
    }

    return .{
        .tags = try tags.toOwnedSlice(gpa),
        .is_non_exhaustive = is_non_exhaustive,
    };
}

fn findVarDeclByNameNear(
    tree: Ast,
    name: []const u8,
    before_offset: Ast.ByteOffset,
) ?Ast.full.VarDecl {
    var best_offset: ?Ast.ByteOffset = null;
    var best_decl: ?Ast.full.VarDecl = null;
    var nearest_after_offset: ?Ast.ByteOffset = null;
    var nearest_after_decl: ?Ast.full.VarDecl = null;

    var index: u32 = 1;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const var_decl = tree.fullVarDecl(node) orelse continue;
        const name_token = var_decl.ast.mut_token + 1;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

        const offset = tree.tokenStart(name_token);
        if (offset < before_offset) {
            if (best_offset == null or offset > best_offset.?) {
                best_offset = offset;
                best_decl = var_decl;
            }
        } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
            nearest_after_offset = offset;
            nearest_after_decl = var_decl;
        }
    }

    return best_decl orelse nearest_after_decl;
}

fn findFnDeclByNameNear(
    tree: Ast,
    name: []const u8,
    before_offset: Ast.ByteOffset,
) ?Ast.full.FnProto {
    var best_offset: ?Ast.ByteOffset = null;
    var best_fn: ?Ast.full.FnProto = null;
    var nearest_after_offset: ?Ast.ByteOffset = null;
    var nearest_after_fn: ?Ast.full.FnProto = null;

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    var index: u32 = 1;
    while (index < tree.nodes.len) : (index += 1) {
        const node: Ast.Node.Index = @enumFromInt(index);
        const fn_decl = zlinter.ast.fnDecl(tree, node, &fn_proto_buffer) orelse continue;

        const name_token = fn_decl.proto.name_token orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;

        const offset = tree.tokenStart(name_token);
        if (offset < before_offset) {
            if (best_offset == null or offset > best_offset.?) {
                best_offset = offset;
                best_fn = fn_decl.proto;
            }
        } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
            nearest_after_offset = offset;
            nearest_after_fn = fn_decl.proto;
        }
    }

    return best_fn orelse nearest_after_fn;
}

fn buildProblemMessage(missing: []const []const u8, gpa: std.mem.Allocator) ![]const u8 {
    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    try aw.writer.writeAll("Enum switch over exhaustive enum must list every tag explicitly; else is not allowed");

    if (missing.len > 0) {
        try aw.writer.writeAll(" (missing: ");
        for (missing, 0..) |tag, i| {
            if (i != 0) try aw.writer.writeAll(", ");
            try aw.writer.print(".{s}", .{tag});
        }
        try aw.writer.writeAll(")");
    }

    return try aw.toOwnedSlice();
}

test {
    std.testing.refAllDecls(@This());
}

test "require_exhaustive_enum_switch" {
    const rule = buildRule(.{});

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum {
        \\    idle,
        \\    running,
        \\    stopped,
        \\};
        \\
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running, .stopped => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_exhaustive_enum_switch",
                .severity = .warning,
                .slice = "switch",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .stopped)",
            },
        },
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        .running => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const State = enum { idle, running, stopped };
        \\pub fn handle(state: State) void {
        \\    switch (state) {
        \\        .idle => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_exhaustive_enum_switch",
                .severity = .warning,
                .slice = "switch",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .running, .stopped)",
            },
        },
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const Number = enum(u8) { one, two, three, _ };
        \\pub fn handle(number: Number) void {
        \\    switch (number) {
        \\        .one => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        rule,
        \\const Ok = enum { a, b, c, d };
        \\const b = Ok.a;
        \\const Other = Ok;
        \\
        \\pub fn references(value: Ok) void {
        \\    switch (value) {
        \\        b => {},
        \\        Other.b => {},
        \\        .c => {},
        \\        else => {},
        \\    }
        \\}
    ,
        .{},
        Config{},
        &.{
            .{
                .rule_id = "require_exhaustive_enum_switch",
                .severity = .warning,
                .slice = "switch",
                .message = "Enum switch over exhaustive enum must list every tag explicitly; else is not allowed (missing: .d)",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
