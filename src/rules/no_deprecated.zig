//! Enforces that references aren't deprecated (i.e., doc commented with `Deprecated:`)
//!
//! If you're indefinitely targetting fixed versions of a dependency or zig
//! then using deprecated items may not be a big deal. Although, it's still
//! worth undertsanding why they're deprecated, as there may be risks associated
//! with use.

/// Config for no_deprecated rule.
pub const Config = struct {
    /// The severity of deprecations (off, warning, error).
    severity: zlinter.rules.LintProblemSeverity = .warning,
};

/// Builds and returns the no_deprecated rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.no_deprecated),
        .run = &run,
    };
}

/// Runs the no_deprecated rule.
fn run(
    rule: zlinter.rules.LintRule,
    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    if (config.severity == .off) return null;

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    defer lint_problems.deinit(gpa);

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var resolver = try NativeResolver.init(context, doc, gpa, arena);
    defer resolver.deinit(gpa);

    const tree = doc.handle.tree;
    var index: u32 = @intFromEnum(Ast.Node.Index.root);
    while (index < tree.nodes.len) : (index += 1) {
        defer _ = arena_allocator.reset(.retain_capacity);

        const node: Ast.Node.Index = @enumFromInt(index);
        const tag = tree.nodeTag(node);
        switch (tag) {
            .enum_literal => try handleEnumLiteral(
                rule,
                gpa,
                arena,
                &resolver,
                doc,
                node,
                &lint_problems,
                config,
            ),
            .field_access => try handleFieldAccess(
                rule,
                gpa,
                arena,
                &resolver,
                doc,
                node,
                &lint_problems,
                config,
            ),
            .identifier => try handleIdentifierAccess(
                rule,
                gpa,
                arena,
                &resolver,
                doc,
                node,
                &lint_problems,
                config,
            ),
            else => {},
        }
    }

    for (lint_problems.items) |*problem| {
        problem.severity = config.severity;
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

fn handleIdentifierAccess(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    resolver: *NativeResolver,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    _ = arena;
    const tree = doc.handle.tree;
    const identifier_token = tree.nodeMainToken(node_index);

    // Skip declaration identifiers; only usage sites should be reported.
    if (isIdentifierDeclarationSite(doc, node_index, identifier_token)) return;

    const source_index = tree.tokens.items(.start)[identifier_token];
    const resolved = resolver.resolveExpr(doc, node_index, source_index, 0) orelse return;
    const deprecated_message = resolver.deprecatedMessageFromResolved(resolved) orelse return;
    defer gpa.free(deprecated_message);

    try lint_problems.append(gpa, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated - {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

fn handleEnumLiteral(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    resolver: *NativeResolver,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    _ = arena;
    const tree = doc.handle.tree;
    const tag_name = tree.tokenSlice(tree.nodeMainToken(node_index));
    const source_index = tree.tokens.items(.start)[tree.nodeMainToken(node_index)];

    const enum_container = resolver.resolveEnumContainerForLiteral(doc, node_index, source_index, 0) orelse return;
    const member = resolver.resolveContainerMember(enum_container, tag_name) orelse return;
    const deprecated_message = resolver.deprecatedMessageFromDecl(member) orelse return;
    defer gpa.free(deprecated_message);

    try lint_problems.append(gpa, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

fn handleFieldAccess(
    rule: zlinter.rules.LintRule,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    resolver: *NativeResolver,
    doc: *const zlinter.session.LintDocument,
    node_index: Ast.Node.Index,
    lint_problems: *std.ArrayList(zlinter.results.LintProblem),
    config: Config,
) !void {
    _ = arena;
    const tree = doc.handle.tree;
    const source_index = tree.tokens.items(.start)[tree.firstToken(node_index)];
    const resolved = resolver.resolveExpr(doc, node_index, source_index, 0) orelse return;
    const deprecated_message = resolver.deprecatedMessageFromResolved(resolved) orelse return;
    defer gpa.free(deprecated_message);

    try lint_problems.append(gpa, .{
        .start = .startOfNode(tree, node_index),
        .end = .endOfNode(tree, node_index),
        .message = try std.fmt.allocPrint(gpa, "Deprecated: {s}", .{deprecated_message}),
        .rule_id = rule.rule_id,
        .severity = config.severity,
    });
}

const NativeResolver = struct {
    const Self = @This();

    context: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    file_cache: std.ArrayList(FileContext),

    const FileContext = struct {
        abs_path: []const u8,
        tree: Ast,
        source_owned: ?[:0]u8 = null,
        is_borrowed: bool = false,
    };

    const DeclRef = struct {
        file_index: usize,
        node: Ast.Node.Index,
    };

    const ContainerRef = struct {
        file_index: usize,
        node: Ast.Node.Index,
    };

    const Resolved = union(enum) {
        decl: DeclRef,
        container: ContainerRef,
        module: usize, // file index
    };

    fn init(
        context: *zlinter.session.LintContext,
        doc: *const zlinter.session.LintDocument,
        gpa: std.mem.Allocator,
        arena: std.mem.Allocator,
    ) !Self {
        var self = Self{
            .context = context,
            .doc = doc,
            .gpa = gpa,
            .file_cache = .empty,
        };
        errdefer self.deinit(gpa);

        const abs_path = try gpa.dupe(u8, doc.path);
        errdefer gpa.free(abs_path);

        try self.file_cache.append(gpa, .{
            .abs_path = abs_path,
            .tree = doc.handle.tree,
            .is_borrowed = true,
        });

        _ = arena;
        return self;
    }

    fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        for (self.file_cache.items) |*file| {
            gpa.free(file.abs_path);
            if (file.source_owned) |source| gpa.free(source);
            if (!file.is_borrowed) file.tree.deinit(gpa);
        }
        self.file_cache.deinit(gpa);
    }

    fn resolveExpr(
        self: *Self,
        doc: *const zlinter.session.LintDocument,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?Resolved {
        if (depth > 16) return null;
        const tree = doc.handle.tree;
        const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });

        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                if (resolveParamTypeNode(doc, unwrapped, name)) |type_node| {
                    if (self.resolveTypeExprToContainer(doc, type_node, before_offset, depth + 1)) |container| {
                        return .{ .container = container };
                    }
                }

                if (self.lookupDeclByNameNear(0, name, before_offset)) |decl| {
                    return self.resolveDeclOrAlias(decl, before_offset, depth + 1);
                }
                return null;
            },
            .field_access => {
                const data = tree.nodeData(unwrapped).node_and_token;
                const lhs = data.@"0";
                const field_token = data.@"1";
                if (tree.tokenTag(field_token) != .identifier) return null;

                const field_name = tree.tokenSlice(field_token);
                const lhs_resolved = self.resolveExpr(doc, lhs, before_offset, depth + 1) orelse return null;
                return self.resolveFieldOnResolved(lhs_resolved, field_name, before_offset, depth + 1);
            },
            else => return null,
        }
    }

    fn resolveDeclOrAlias(self: *Self, decl: DeclRef, _: Ast.ByteOffset, depth: u8) ?Resolved {
        if (depth > 16) return null;
        const file = self.file_cache.items[decl.file_index];
        const tree = file.tree;

        if (tree.fullVarDecl(decl.node)) |var_decl| {
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                if (self.resolveImportFromInit(decl.file_index, init_node)) |import_file_index| {
                    return .{ .module = import_file_index };
                }
            }
            return .{ .decl = decl };
        }

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        if (tree.fullFnProto(&fn_proto_buffer, decl.node)) |_| {
            return .{ .decl = decl };
        }

        var container_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_buffer, decl.node)) |_| {
            return .{ .container = .{ .file_index = decl.file_index, .node = decl.node } };
        }

        return .{ .decl = decl };
    }

    fn resolveExprInFile(self: *Self, file_index: usize, node: Ast.Node.Index, before_offset: Ast.ByteOffset, depth: u8) ?Resolved {
        const file = self.file_cache.items[file_index];
        if (file_index == 0) return self.resolveExpr(self.doc, node, before_offset, depth);
        if (depth > 16) return null;
        const tree = file.tree;
        const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });
        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                if (self.lookupDeclByNameNear(file_index, name, before_offset)) |decl| {
                    return self.resolveDeclOrAlias(decl, before_offset, depth + 1);
                }
                return null;
            },
            .field_access => {
                const data = tree.nodeData(unwrapped).node_and_token;
                const lhs = data.@"0";
                const field_token = data.@"1";
                if (tree.tokenTag(field_token) != .identifier) return null;
                const field_name = tree.tokenSlice(field_token);
                const lhs_resolved = self.resolveExprInFile(file_index, lhs, before_offset, depth + 1) orelse return null;
                return self.resolveFieldOnResolved(lhs_resolved, field_name, before_offset, depth + 1);
            },
            else => return null,
        }
    }

    fn resolveFieldOnResolved(
        self: *Self,
        resolved: Resolved,
        field_name: []const u8,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?Resolved {
        if (depth > 16) return null;
        switch (resolved) {
            .module => |file_index| {
                const decl = self.lookupTopLevelDecl(file_index, field_name) orelse return null;
                return self.resolveDeclOrAlias(decl, before_offset, depth + 1);
            },
            .container => |container| {
                const member = self.resolveContainerMember(container, field_name) orelse return null;
                return self.resolveDeclOrAlias(member, before_offset, depth + 1);
            },
            .decl => |decl| {
                if (self.resolveVarInitResolved(decl, depth + 1)) |target| {
                    const member = self.resolveFieldOnResolved(target, field_name, before_offset, depth + 1) orelse return null;
                    return member;
                }
                if (self.resolveContainerFromDecl(decl, before_offset, depth + 1)) |container| {
                    const member = self.resolveContainerMember(container, field_name) orelse return null;
                    return self.resolveDeclOrAlias(member, before_offset, depth + 1);
                }
                return null;
            },
        }
    }

    fn resolveContainerFromDecl(self: *Self, decl: DeclRef, before_offset: Ast.ByteOffset, depth: u8) ?ContainerRef {
        if (depth > 16) return null;
        const file = self.file_cache.items[decl.file_index];
        const tree = file.tree;

        if (tree.fullContainerField(decl.node)) |field| {
            const type_node = field.ast.type_expr.unwrap() orelse return null;
            return self.resolveTypeExprInFile(decl.file_index, type_node, before_offset, depth + 1);
        }

        if (tree.fullVarDecl(decl.node)) |var_decl| {
            if (var_decl.ast.type_node.unwrap()) |type_node| {
                if (self.resolveTypeExprInFile(decl.file_index, type_node, before_offset, depth + 1)) |container| {
                    return container;
                }
            }
            if (var_decl.ast.init_node.unwrap()) |init_node| {
                var struct_init_buffer: [2]Ast.Node.Index = undefined;
                if (tree.fullStructInit(&struct_init_buffer, init_node)) |struct_init| {
                    if (struct_init.ast.type_expr.unwrap()) |type_expr| {
                        if (self.resolveTypeExprInFile(decl.file_index, type_expr, before_offset, depth + 1)) |container| {
                            return container;
                        }
                    }
                }
                if (self.resolveContainerFromNode(decl.file_index, init_node, before_offset, depth + 1)) |container| {
                    return container;
                }
            }
        }

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_decl_buffer, decl.node)) |_| {
            return .{ .file_index = decl.file_index, .node = decl.node };
        }

        return null;
    }

    fn resolveVarInitResolved(self: *Self, decl: DeclRef, depth: u8) ?Resolved {
        if (depth > 16) return null;
        const file = self.file_cache.items[decl.file_index];
        const tree = file.tree;
        const var_decl = tree.fullVarDecl(decl.node) orelse return null;
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;

        if (self.resolveImportFromInit(decl.file_index, init_node)) |import_file_index| {
            return .{ .module = import_file_index };
        }

        const init_offset = tree.tokenStart(tree.firstToken(init_node));
        const resolved = self.resolveExprInFile(decl.file_index, init_node, init_offset, depth + 1) orelse return null;
        return switch (resolved) {
            .module, .container => resolved,
            .decl => null,
        };
    }

    fn resolveContainerFromNode(
        self: *Self,
        file_index: usize,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        const tree = self.file_cache.items[file_index].tree;
        const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });

        var buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&buffer, unwrapped)) |_| {
            return .{ .file_index = file_index, .node = unwrapped };
        }

        if (self.resolveTypeExprInFile(file_index, unwrapped, before_offset, depth + 1)) |container| {
            return container;
        }

        return null;
    }

    fn resolveTypeExprToContainer(
        self: *Self,
        _: *const zlinter.session.LintDocument,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        return self.resolveTypeExprInFile(0, node, before_offset, depth);
    }

    fn resolveTypeExprInFile(
        self: *Self,
        file_index: usize,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        const tree = self.file_cache.items[file_index].tree;
        const unwrapped = zlinter.ast.unwrapNode(tree, node, .{
            .unwrap_optional_unwrap = false,
        });

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        if (tree.fullContainerDecl(&container_decl_buffer, unwrapped)) |_| {
            return .{ .file_index = file_index, .node = unwrapped };
        }

        switch (tree.nodeTag(unwrapped)) {
            .identifier => {
                const name = tree.getNodeSource(unwrapped);
                const decl = self.lookupDeclByNameNear(file_index, name, before_offset) orelse return null;
                return self.resolveContainerFromDecl(decl, before_offset, depth + 1);
            },
            .field_access => {
                const data = tree.nodeData(unwrapped).node_and_token;
                const lhs = data.@"0";
                const field_token = data.@"1";
                if (tree.tokenTag(field_token) != .identifier) return null;
                const field_name = tree.tokenSlice(field_token);

                const lhs_resolved = self.resolveExprInFile(file_index, lhs, before_offset, depth + 1) orelse return null;
                const rhs_resolved = self.resolveFieldOnResolved(lhs_resolved, field_name, before_offset, depth + 1) orelse return null;
                return switch (rhs_resolved) {
                    .container => |container| container,
                    .decl => |decl| self.resolveContainerFromDecl(decl, before_offset, depth + 1),
                    .module => null,
                };
            },
            else => return null,
        }
    }

    fn resolveEnumContainerForLiteral(
        self: *Self,
        doc: *const zlinter.session.LintDocument,
        node: Ast.Node.Index,
        before_offset: Ast.ByteOffset,
        depth: u8,
    ) ?ContainerRef {
        if (depth > 16) return null;
        const tree = doc.handle.tree;

        var current = node;
        while (doc.lineage.items(.parent)[@intFromEnum(current)]) |parent| {
            current = parent;

            if (tree.fullVarDecl(current)) |var_decl| {
                const type_node = var_decl.ast.type_node.unwrap() orelse return null;
                const container = self.resolveTypeExprToContainer(doc, type_node, before_offset, depth + 1) orelse return null;
                if (self.isEnumContainer(container)) return container;
                return null;
            }

            if (tree.fullContainerField(current)) |field| {
                const type_node = field.ast.type_expr.unwrap() orelse return null;
                const container = self.resolveTypeExprToContainer(doc, type_node, before_offset, depth + 1) orelse return null;
                if (self.isEnumContainer(container)) return container;
                return null;
            }

            var struct_init_buffer: [2]Ast.Node.Index = undefined;
            if (tree.fullStructInit(&struct_init_buffer, current)) |struct_init| {
                const field_name = inferStructInitFieldName(tree, struct_init, node) orelse return null;
                const init_type_node = struct_init.ast.type_expr.unwrap() orelse return null;
                const init_container = self.resolveTypeExprToContainer(doc, init_type_node, before_offset, depth + 1) orelse return null;

                const member = self.resolveContainerMember(init_container, field_name) orelse return null;
                const member_container = self.resolveContainerFromDecl(member, before_offset, depth + 1) orelse return null;
                if (self.isEnumContainer(member_container)) return member_container;
                return null;
            }
        }

        return null;
    }

    fn isEnumContainer(self: *Self, container: ContainerRef) bool {
        const file = self.file_cache.items[container.file_index];
        var buffer: [2]Ast.Node.Index = undefined;
        const full = file.tree.fullContainerDecl(&buffer, container.node) orelse return false;
        return file.tree.tokens.items(.tag)[full.ast.main_token] == .keyword_enum;
    }

    fn resolveContainerMember(self: *Self, container: ContainerRef, member_name: []const u8) ?DeclRef {
        const file = self.file_cache.items[container.file_index];
        const tree = file.tree;

        var container_decl_buffer: [2]Ast.Node.Index = undefined;
        const full = tree.fullContainerDecl(&container_decl_buffer, container.node) orelse return null;

        for (full.ast.members) |member| {
            switch (tree.nodeTag(member)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    const token = tree.nodeMainToken(member);
                    if (std.mem.eql(u8, tree.tokenSlice(token), member_name)) {
                        return .{ .file_index = container.file_index, .node = member };
                    }
                },
                .fn_decl => {
                    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
                    const fn_decl = zlinter.ast.fnDecl(tree, member, &fn_proto_buffer) orelse continue;
                    const name_token = fn_decl.proto.name_token orelse continue;
                    if (std.mem.eql(u8, tree.tokenSlice(name_token), member_name)) {
                        return .{ .file_index = container.file_index, .node = member };
                    }
                },
                .simple_var_decl,
                .local_var_decl,
                .global_var_decl,
                .aligned_var_decl,
                => {
                    const var_decl = tree.fullVarDecl(member).?;
                    const name_token = var_decl.ast.mut_token + 1;
                    if (std.mem.eql(u8, tree.tokenSlice(name_token), member_name)) {
                        return .{ .file_index = container.file_index, .node = member };
                    }
                },
                else => {},
            }
        }

        return null;
    }

    fn resolveImportFromInit(self: *Self, file_index: usize, init_node: Ast.Node.Index) ?usize {
        const file = self.file_cache.items[file_index];
        const tree = file.tree;

        const unwrapped = zlinter.ast.unwrapNode(tree, init_node, .{
            .unwrap_optional_unwrap = false,
        });

        switch (tree.nodeTag(unwrapped)) {
            .builtin_call_two,
            .builtin_call_two_comma,
            => {
                if (!std.mem.eql(u8, "@import", tree.tokenSlice(tree.nodeMainToken(unwrapped)))) return null;
                const data = tree.nodeData(unwrapped);
                const arg_node = data.opt_node_and_opt_node[0].unwrap() orelse return null;
                if (tree.nodeTag(arg_node) != .string_literal) return null;

                const import_token = tree.nodeMainToken(arg_node);
                const import_slice = tree.tokenSlice(import_token);
                if (import_slice.len < 2) return null;

                const import_path = import_slice[1 .. import_slice.len - 1];
                if (std.mem.eql(u8, import_path, "std")) return null;

                const abs_path = resolveImportPathAlloc(
                    self.context,
                    self.doc,
                    file.abs_path,
                    import_path,
                    self.gpa,
                ) orelse return null;
                defer self.gpa.free(abs_path);

                return self.getOrLoadFileByAbsPath(abs_path) catch null;
            },
            else => return null,
        }
    }

    fn getOrLoadFileByAbsPath(self: *Self, abs_path: []const u8) !usize {
        for (self.file_cache.items, 0..) |file, i| {
            if (std.mem.eql(u8, file.abs_path, abs_path)) return i;
        }

        const source = std.Io.Dir.cwd().readFileAllocOptions(
            self.context.io,
            abs_path,
            self.gpa,
            .limited(max_file_size_bytes),
            .of(u8),
            0,
        ) catch return error.FileNotFound;
        errdefer self.gpa.free(source);

        var source_z: [:0]u8 = try self.gpa.allocSentinel(u8, source.len, 0);
        errdefer self.gpa.free(source_z);
        @memcpy(source_z[0..source.len], source);
        self.gpa.free(source);

        var tree = try Ast.parse(self.gpa, source_z, .zig);
        errdefer tree.deinit(self.gpa);

        try self.file_cache.append(self.gpa, .{
            .abs_path = try self.gpa.dupe(u8, abs_path),
            .tree = tree,
            .source_owned = source_z,
            .is_borrowed = false,
        });
        return self.file_cache.items.len - 1;
    }

    fn lookupTopLevelDecl(self: *Self, file_index: usize, name: []const u8) ?DeclRef {
        const file = self.file_cache.items[file_index];
        const tree = file.tree;

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        for (tree.rootDecls()) |decl| {
            if (tree.fullVarDecl(decl)) |var_decl| {
                const name_token = var_decl.ast.mut_token + 1;
                if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) {
                    return .{ .file_index = file_index, .node = decl };
                }
            } else if (zlinter.ast.fnDecl(tree, decl, &fn_proto_buffer)) |fn_decl| {
                const name_token = fn_decl.proto.name_token orelse continue;
                if (std.mem.eql(u8, tree.tokenSlice(name_token), name)) {
                    return .{ .file_index = file_index, .node = decl };
                }
            }
        }

        return null;
    }

    fn lookupDeclByNameNear(self: *Self, file_index: usize, name: []const u8, before_offset: Ast.ByteOffset) ?DeclRef {
        const file = self.file_cache.items[file_index];
        const tree = file.tree;

        var best_offset: ?Ast.ByteOffset = null;
        var best_decl: ?DeclRef = null;
        var nearest_after_offset: ?Ast.ByteOffset = null;
        var nearest_after_decl: ?DeclRef = null;

        var fn_proto_buffer: [1]Ast.Node.Index = undefined;
        var index: u32 = 1;
        while (index < tree.nodes.len) : (index += 1) {
            const node: Ast.Node.Index = @enumFromInt(index);

            if (tree.fullVarDecl(node)) |var_decl| {
                const name_token = var_decl.ast.mut_token + 1;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
                const offset = tree.tokenStart(name_token);
                if (offset < before_offset) {
                    if (best_offset == null or offset > best_offset.?) {
                        best_offset = offset;
                        best_decl = .{ .file_index = file_index, .node = node };
                    }
                } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
                    nearest_after_offset = offset;
                    nearest_after_decl = .{ .file_index = file_index, .node = node };
                }
                continue;
            }

            if (zlinter.ast.fnDecl(tree, node, &fn_proto_buffer)) |fn_decl| {
                const name_token = fn_decl.proto.name_token orelse continue;
                if (!std.mem.eql(u8, tree.tokenSlice(name_token), name)) continue;
                const offset = tree.tokenStart(name_token);
                if (offset < before_offset) {
                    if (best_offset == null or offset > best_offset.?) {
                        best_offset = offset;
                        best_decl = .{ .file_index = file_index, .node = node };
                    }
                } else if (nearest_after_offset == null or offset < nearest_after_offset.?) {
                    nearest_after_offset = offset;
                    nearest_after_decl = .{ .file_index = file_index, .node = node };
                }
            }
        }

        return best_decl orelse nearest_after_decl;
    }

    fn deprecatedMessageFromResolved(self: *Self, resolved: Resolved) ?[]const u8 {
        return switch (resolved) {
            .decl => |decl| self.deprecatedMessageFromDecl(decl),
            .container => |container| self.deprecatedMessageFromDecl(.{ .file_index = container.file_index, .node = container.node }),
            .module => null,
        };
    }

    fn deprecatedMessageFromDecl(self: *Self, decl: DeclRef) ?[]const u8 {
        const file = self.file_cache.items[decl.file_index];
        return deprecationFromNodeDoc(file.tree, decl.node, self.gpa) catch null;
    }
};

fn deprecationFromNodeDoc(tree: Ast, node: Ast.Node.Index, gpa: std.mem.Allocator) !?[]const u8 {
    const first_token = tree.firstToken(node);
    if (first_token == 0) return null;

    const token = first_token - 1;
    const is_doc = switch (tree.tokenTag(token)) {
        .doc_comment, .container_doc_comment => true,
        else => false,
    };
    if (!is_doc) return null;

    var start = token;
    while (start > 0) : (start -= 1) {
        const prev = start - 1;
        switch (tree.tokenTag(prev)) {
            .doc_comment, .container_doc_comment => {},
            else => break,
        }
    }

    var aw = std.Io.Writer.Allocating.init(gpa);
    defer aw.deinit();

    var i = start;
    while (i <= token) : (i += 1) {
        const slice = tree.tokenSlice(i);
        const body = switch (tree.tokenTag(i)) {
            .doc_comment => if (slice.len >= 3) slice[3..] else slice,
            .container_doc_comment => if (slice.len >= 3) slice[3..] else slice,
            else => slice,
        };
        try aw.writer.writeAll(body);
        try aw.writer.writeByte('\n');
    }

    const doc_text = try aw.toOwnedSlice();
    defer gpa.free(doc_text);
    return if (getDeprecationFromDoc(doc_text)) |dep|
        try gpa.dupe(u8, dep)
    else
        null;
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

fn isIdentifierDeclarationSite(
    doc: *const zlinter.session.LintDocument,
    node: Ast.Node.Index,
    identifier_token: Ast.TokenIndex,
) bool {
    const tree = doc.handle.tree;
    var current = node;
    while (doc.lineage.items(.parent)[@intFromEnum(current)]) |parent| {
        current = parent;
        if (tree.fullVarDecl(current)) |var_decl| {
            return var_decl.ast.mut_token + 1 == identifier_token;
        }
        if (tree.nodeTag(current) == .fn_decl) {
            var fn_proto_buffer: [1]Ast.Node.Index = undefined;
            const fn_decl = zlinter.ast.fnDecl(tree, current, &fn_proto_buffer) orelse return false;
            return fn_decl.proto.name_token != null and fn_decl.proto.name_token.? == identifier_token;
        }
        if (tree.fullContainerField(current)) |field| {
            const name_token = field.ast.main_token;
            return name_token == identifier_token;
        }
    }
    return false;
}

fn inferStructInitFieldName(
    tree: Ast,
    struct_init: Ast.full.StructInit,
    value_node: Ast.Node.Index,
) ?[]const u8 {
    for (struct_init.ast.fields) |field_node| {
        if (field_node != value_node) continue;

        const first = tree.firstToken(field_node);
        if (first < 3) return null;
        if (tree.tokenTag(first - 1) != .equal) return null;
        if (tree.tokenTag(first - 2) != .identifier) return null;
        if (tree.tokenTag(first - 3) != .period) return null;
        return tree.tokenSlice(first - 2);
    }
    return null;
}

fn resolveImportPathAlloc(
    _: *zlinter.session.LintContext,
    _: *const zlinter.session.LintDocument,
    importer_abs_path: []const u8,
    import_path: []const u8,
    gpa: std.mem.Allocator,
) ?[]const u8 {
    if (!(std.mem.startsWith(u8, import_path, "./") or std.mem.startsWith(u8, import_path, "../"))) return null;

    const importer_dir = std.fs.path.dirname(importer_abs_path) orelse return null;
    return std.fs.path.resolve(gpa, &.{ importer_dir, import_path }) catch null;
}

const max_file_size_bytes = 8 * 1024 * 1024;

/// Returns a slice of a deprecation notice if one was found.
///
/// Deprecation notices must appear on a single document comment line.
fn getDeprecationFromDoc(doc: []const u8) ?[]const u8 {
    var line_it = std.mem.splitScalar(u8, doc, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trim(
            u8,
            line,
            &std.ascii.whitespace,
        );

        for ([_][]const u8{
            "deprecated:",
            "deprecated;",
            "deprecated,",
            "deprecated.",
            "deprecated ",
            "deprecated-",
        }) |line_prefix| {
            if (doc.len < line_prefix.len) continue;
            if (!std.ascii.startsWithIgnoreCase(trimmed, line_prefix)) continue;

            return std.mem.trim(
                u8,
                trimmed[line_prefix.len..],
                &std.ascii.whitespace,
            );
        }
    }
    return null;
}

test getDeprecationFromDoc {
    try std.testing.expectEqualStrings("", getDeprecationFromDoc("DEPRECATED:").?);
    try std.testing.expectEqualStrings("", getDeprecationFromDoc("deprecated; ").?);
    try std.testing.expectEqualStrings("Hello world", getDeprecationFromDoc("DepreCATED-  Hello world").?);
    try std.testing.expectEqualStrings("Hello world", getDeprecationFromDoc("DEPRECATED  Hello world\nAnother comment").?);
    try std.testing.expectEqualStrings("Hello world", getDeprecationFromDoc("DEPrecated,\t  Hello world  \t  ").?);
    try std.testing.expectEqualStrings("use x instead", getDeprecationFromDoc(" Comment above\n deprecated. use x instead\t  \n Comment underneath").?);

    try std.testing.expectEqual(null, getDeprecationFromDoc(""));
    try std.testing.expectEqual(null, getDeprecationFromDoc("DEPRECATE: "));
    try std.testing.expectEqual(null, getDeprecationFromDoc("deprecatttteeeedddd: "));
    try std.testing.expectEqual(null, getDeprecationFromDoc(" "));
}

test {
    std.testing.refAllDecls(@This());
}

test "no_deprecated - regression test for #36" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\const convention: namespace.CallingConvention = .Stdcall;
        \\
        \\const namespace = struct {
        \\  const CallingConvention = enum {
        \\    /// Deprecated: Don't use
        \\    Stdcall,
        \\    std_call,
        \\  };
        \\};
    ,
        .{},
        Config{ .severity = .@"error" },
        &.{
            .{
                .rule_id = "no_deprecated",
                .severity = .@"error",
                .slice = ".Stdcall",
                .message = "Deprecated: Don't use",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const ast = zlinter.ast;
const Ast = std.zig.Ast;
