//! The context of all document and rule executions. It'll live the duration
//! of linting all zig source files.
const LintContext = @This();

gpa: std.mem.Allocator,
arena: std.mem.Allocator,
io: std.Io,

/// Externally owned slice to zig executable path
zig_exe: []const u8,

/// Externally owned slice to zig lib directory path
zig_lib_directory: []const u8,

/// Externally owned slice to current working directory
cwd: []const u8,

compile_contexts: std.MultiArrayList(CompileContext) = .empty,
file_store: FileStore = .empty,
module_store: ModuleStore = .empty,
decl_store: DeclStore = undefined, // zlinter-disable-current-line no_undefined - set in init
type_store: TypeStore = .empty,
build_config_store: BuildConfigStore = .empty,

pub fn init(self: *LintContext) !void {
    const zone = tracy.traceNamed(@src(), "LintContext.init");
    defer zone.end();

    // TODO: #149 - refactor to not do this
    self.decl_store = .{
        .gpa = self.gpa,
        .zig_lib_directory = self.zig_lib_directory,
        .io = self.io,
    };

    // TODO: #149 - investigate using fake BuildConfigStore
    if (!builtin.is_test) try self.initBuildConfig();
}

pub fn deinit(self: *LintContext) void {
    self.build_config_store.deinit(self.gpa);
    self.file_store.deinit(self.gpa);
    self.compile_contexts.deinit(self.gpa);
    self.module_store.deinit(self.gpa);
    self.decl_store.deinit(self.gpa);
    self.type_store.deinit(self.gpa);
}

fn initBuildConfig(self: *LintContext) !void {
    const zone = tracy.traceNamed(@src(), "LintContext.initBuildConfig");
    defer zone.end();

    const config_id = try self.build_config_store.resolve(
        self.io,
        self.gpa,
        self.zig_exe,
        self.cwd,
        ".",
    );

    const build_config = self.build_config_store.buildConfig(config_id);
    for (0..build_config.steps.len) |step_index|
        try self.consumeBuildConfigStep(
            config_id,
            @enumFromInt(step_index),
        );
}

fn consumeBuildConfigStep(
    self: *LintContext,
    config_id: BuildConfigStore.ConfigId,
    step_index: std.Build.Configuration.Step.Index,
) !void {
    const zone = tracy.traceNamed(@src(), "LintContext.consumeBuildConfigStep");
    defer zone.end();

    const build_config = self.build_config_store.buildConfig(config_id);
    const step = build_config.steps[@intFromEnum(step_index)];

    const compile = step.extended.cast(
        build_config,
        std.Build.Configuration.Step.Compile,
    ) orelse return;

    const root_module_id = try self.resolveBuildModule(
        config_id,
        compile.root_module,
    ) orelse {
        std.log.info(
            "Step '{s}' has no root module with a root source path",
            .{step.name.slice(build_config)},
        );
        return;
    };

    // TODO: #149 - should we bother doing this?
    // for (self.module_store.modules.items(.root_file)) |module_root_file_id| {
    //     _ = self.decl_store.store(
    //         module_root_file_id,
    //         &self.file_store,
    //         self.gpa,
    //     );
    // }
    // const root_file_id = self.module_store.rootFile(root_module_id);
    // _ = self.decl_store.store(
    //     root_file_id,
    //     &self.file_store,
    //     self.gpa,
    // );

    const compile_context_id: CompileContext.Id = .fromIndex(self.compile_contexts.len);
    try self.compile_contexts.append(self.gpa, .{
        .step_index = step_index,
        .root_module = root_module_id,
    });
    errdefer _ = self.compile_contexts.swapRemove(compile_context_id.toIndex());

    // TODO: #149 - this is still experimental descendents population.
    // {
    //     var map: std.AutoHashMapUnmanaged(files.Import, void) = .empty;
    //     defer map.deinit(self.gpa);

    //     var it: files.ImportIterator = .{
    //         .file_store = &self.file_store,
    //         .io = self.io,
    //         .cwd = std.fs.path.dirname(self.file_store.fileAbsPath(root_file_id)) orelse self.cwd,
    //         .gpa = self.gpa,
    //         .zig_lib_directory = self.zig_lib_directory,
    //     };
    //     defer it.deinit();

    //     try it.init(root_file_id);
    //     while (try it.next()) |child_import| {
    //         try map.put(self.gpa, child_import, {});
    //         std.debug.print(" Visited Descendent: '{t}' '{s}'\n", .{
    //             child_import.kind,
    //             self.file_store.fileAbsPath(child_import.file_id),
    //         });

    //         _ = self.decl_store.store(
    //             child_import.file_id,
    //             &self.file_store,
    //             self.gpa,
    //         );
    //     }
    // }
}

fn resolveBuildModule(
    self: *LintContext,
    config_id: BuildConfigStore.ConfigId,
    build_module_index: std.Build.Configuration.Module.Index,
) !?ModuleStore.ModuleId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveBuildModule");
    defer zone.end();

    const build_config = self.build_config_store.buildConfig(config_id);

    var seen: std.AutoHashMapUnmanaged(
        std.Build.Configuration.Module.Index,
        ModuleStore.ModuleId,
    ) = .empty;
    defer seen.deinit(self.gpa);

    var queue: std.ArrayList(std.Build.Configuration.Module.Index) = .empty;
    defer queue.deinit(self.gpa);

    const root_module_id = try self.resolveBuildModuleShallow(
        config_id,
        build_module_index,
    ) orelse return null;

    try seen.put(self.gpa, build_module_index, root_module_id);
    try queue.append(self.gpa, build_module_index);

    while (queue.pop()) |current_build_module_index| {
        const current_module_id = seen.get(current_build_module_index).?;

        // This exact build module may already have been populated by an earlier compile step.
        if (self.module_store.namedImports(current_module_id).count() != 0) {
            continue;
        }

        const build_module = current_build_module_index.get(build_config);

        const imports = build_module.import_table.get(build_config).imports.mal;
        var named_imports: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;
        errdefer {
            var it = named_imports.keyIterator();
            while (it.next()) |key| self.gpa.free(key.*);
            named_imports.deinit(self.gpa);
        }

        try named_imports.ensureTotalCapacity(self.gpa, @intCast(imports.len));
        for (imports.items(.name), imports.items(.module)) |
            build_import_name_id,
            build_import_module_index,
        | {
            const import_name_slice = build_import_name_id.slice(build_config);

            const import_module_id = seen.get(build_import_module_index) orelse child: {
                const resolved = (try self.resolveBuildModuleShallow(
                    config_id,
                    build_import_module_index,
                )) orelse continue;

                try seen.put(self.gpa, build_import_module_index, resolved);
                try queue.append(self.gpa, build_import_module_index);

                break :child resolved;
            };

            named_imports.putAssumeCapacity(
                try self.gpa.dupe(u8, import_name_slice),
                import_module_id,
            );
        }

        self.module_store.modules.items(.named_imports)[current_module_id.toIndex()] = named_imports;
        named_imports = .empty;
    }

    return root_module_id;
}

/// Resolves everything except its descendents (e.g., named imports)
fn resolveBuildModuleShallow(
    self: *LintContext,
    config_id: BuildConfigStore.ConfigId,
    build_module_index: std.Build.Configuration.Module.Index,
) !?ModuleStore.ModuleId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveBuildModuleShallow");
    defer zone.end();

    const build_root_path = self.build_config_store.buildRootPath(config_id);
    const build_config = self.build_config_store.buildConfig(config_id);

    const build_module = build_module_index.get(build_config);
    const root_source_file_id = build_module.root_source_file.unwrap() orelse return null;
    const root_source_file = root_source_file_id.get(build_config);
    const root_path = try files.resolveLazyPath(
        root_source_file,
        build_config,
        self.gpa,
        build_root_path,
    ) orelse return null;
    defer self.gpa.free(root_path);

    return try self.module_store.resolve(self.gpa, .{
        .root_file = try self.file_store.resolve(
            root_path,
            self.io,
            self.gpa,
            self.cwd,
        ),
        .build_config = config_id,
        .build_config_module = build_module_index,
        .named_imports = .empty,
    });
}

pub fn resolveFile(self: *LintContext, input_path: []const u8) !FileStore.FileId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveFile");
    defer zone.end();

    const id = try self.file_store.resolve(
        input_path,
        self.io,
        self.gpa,
        self.cwd,
    );
    self.decl_store.resolveFileTypes(
        id,
        &self.file_store,
        &self.module_store,
        &self.type_store,
        self.gpa,
    );
    return id;
}

pub const CompiledContextIterator = struct {
    ctx: *const LintContext,
    file_id: FileStore.FileId,

    index: usize = 0,

    pub fn next(self: *CompiledContextIterator) ?CompileContext.Id {
        while (self.index < self.ctx.compile_contexts.len) {
            const index = self.index;
            self.index += 1;

            _ = index;
            // TODO: #149 - bring back
            // if (self.ctx.include_descendents.items[index].contains(self.file_id)) {
            //     return @intCast(index);
            // }
        }
        return null;
    }
};

pub fn resolveCompiledUnits(
    self: *const LintContext,
    file_id: FileStore.FileId,
) CompiledContextIterator {
    return .{
        .ctx = self,
        .file_id = file_id,
    };
}

pub fn debugPrintFileDecls(self: *const LintContext, file_id: FileStore.FileId) void {
    self.decl_store.debugPrintFileDecls(
        file_id,
        &self.file_store,
        &self.type_store,
    );
}

/// Loads and parses zig file into the document store.
///
/// Caller is responsible for calling deinit once done.
pub fn initDocument(
    self: *LintContext,
    file_id: FileStore.FileId,
    gpa: std.mem.Allocator,
    doc: *LintDocument,
) !void {
    const zone = tracy.traceNamed(@src(), "LintContext.initDocument");
    defer zone.end();

    const abs_path = self.file_store.fileAbsPath(file_id);
    std.debug.assert(std.fs.path.isAbsolute(abs_path));

    const source = self.file_store.fileSource(file_id);
    const tree = self.file_store.fileTree(file_id);

    var src_comments = try comments.allocParse(source, gpa);
    errdefer src_comments.deinit(gpa);

    doc.* = .{
        .file_id = file_id,
        .lineage = .empty,
        .comments = src_comments,
        .skipper = undefined, // zlinter-disable-current-line no_undefined - set below
    };
    errdefer doc.lineage.deinit(gpa);

    doc.skipper = .init(doc.comments, source, gpa);
    errdefer doc.skipper.deinit();

    {
        try doc.lineage.resize(gpa, tree.nodes.len);
        for (0..tree.nodes.len) |i| {
            doc.lineage.set(i, .{});
        }

        const QueueItem = struct {
            parent: ?Ast.Node.Index = null,
            node: Ast.Node.Index,
        };

        var queue = std.ArrayList(QueueItem).empty;
        defer queue.deinit(gpa);

        try queue.append(gpa, .{ .node = .root });

        while (queue.pop()) |item| {
            const children = try ast.nodeChildrenAlloc(
                gpa,
                tree,
                item.node,
            );

            // Ideally this is never necessary as we should only be visiting
            // each node once while walking the tree and if we're not there's
            // another bug but for now to be safe memory wise we'll ensure
            // the previous is cleaned up if needed (no-op if not needed)
            doc.lineage.get(@intFromEnum(item.node)).deinit(gpa);
            doc.lineage.set(@intFromEnum(item.node), .{
                .parent = if (item.parent) |p|
                    p
                else
                    null,
                .children = children,
            });

            for (children) |child| {
                try queue.append(gpa, .{
                    .parent = item.node,
                    .node = child,
                });
            }
        }
    }
}

pub const ResolvedNodeType = struct {
    summary: TypeStore.TypeSummary,
    decl_id: DeclStore.DeclId,
};

/// Resolves the type summary for an expression node.
///
/// This first resolves the expression to the declaration it names, then asks
/// `DeclStore` to normalize container aliases such as `const Self = @This();`.
/// The returned `decl_id` is the declaration whose resolved type produced the
/// summary, not necessarily the declaration textually named by `node`.
pub fn resolveTypeOfNode(
    self: *LintContext,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?ResolvedNodeType {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveTypeOfNode");
    defer zone.end();

    const immediate_decl_id = self.immediateDeclForNode(doc, node);
    const resolved_decl_id = if (immediate_decl_id) |decl_id|
        self.decl_store.resolvedContainerDecl(
            &self.file_store,
            decl_id,
        ) orelse decl_id
    else
        null;

    if (resolved_decl_id) |decl_id| {
        if (self.decl_store.declResolvedType(decl_id)) |type_id| {
            return .{
                .summary = self.type_store.summary(type_id),
                .decl_id = decl_id,
            };
        }
    }

    return null;
}

/// Resolves `node` to the declaration it directly names.
pub fn resolveDeclOfNode(
    self: *LintContext,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclOfNode");
    defer zone.end();

    return self.immediateDeclForNode(doc, node);
}

/// Resolves a member declaration from a container/type declaration.
pub fn resolveDeclMember(
    self: *LintContext,
    parent_decl_id: DeclStore.DeclId,
    member_name: []const u8,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclMember");
    defer zone.end();

    return self.decl_store.resolveMemberDecl(
        &self.file_store,
        &self.module_store,
        parent_decl_id,
        member_name,
    );
}

/// Resolves a member from the type represented by a declaration.
pub fn resolveDeclTypeMember(
    self: *LintContext,
    parent_decl_id: DeclStore.DeclId,
    member_name: []const u8,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclTypeMember");
    defer zone.end();

    return self.decl_store.resolveDeclTypeMember(
        &self.file_store,
        &self.module_store,
        parent_decl_id,
        member_name,
    );
}

/// Resolves the declaration named by a declaration's type expression.
pub fn resolveDeclTypeDecl(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclTypeDecl");
    defer zone.end();

    return self.decl_store.resolveDeclTypeDecl(
        &self.file_store,
        &self.module_store,
        decl_id,
    );
}

/// Returns the cached concrete type target for a declaration, when one was
/// resolved while indexing the file.
pub fn declResolvedTypeTarget(
    self: *const LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclStore.TypeTarget {
    return self.decl_store.declResolvedTypeTarget(decl_id);
}

/// Returns the cached concrete type declaration for a declaration, when one
/// was resolved while indexing the file and is represented by a declaration.
pub fn declResolvedTypeDecl(
    self: *const LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    return self.decl_store.declResolvedTypeDecl(decl_id);
}

pub const EnumInfo = struct {
    file_id: FileStore.FileId,
    container_node: Ast.Node.Index,
    is_non_exhaustive: bool,

    pub fn containerDecl(
        self: EnumInfo,
        context: *const LintContext,
        buffer: *[2]Ast.Node.Index,
    ) ?Ast.full.ContainerDecl {
        const tree = context.file_store.fileTree(self.file_id);
        return tree.fullContainerDecl(buffer, self.container_node);
    }

    pub fn tagName(self: EnumInfo, context: *const LintContext, member: Ast.Node.Index) ?[]const u8 {
        return enumMemberTagName(context.file_store.fileTree(self.file_id), member);
    }
};

inline fn enumMemberTagName(tree: Ast, member: Ast.Node.Index) ?[]const u8 {
    // zlinter-disable-next-line require_exhaustive_enum_switch
    return switch (tree.nodeTag(member)) {
        .container_field,
        .container_field_align,
        .container_field_init,
        => tree.tokenSlice(tree.nodeMainToken(member)),
        else => null,
    };
}

/// Resolves an expression to the concrete enum declaration that determines its
/// values. This preserves enum identity where a coarse type summary such as
/// `.enum_instance` cannot list the enum's tags.
pub fn resolveEnumDeclOfNode(
    self: *LintContext,
    doc: *const LintDocument,
    expr_node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const tree = doc.tree(self);
    const node = ast.unwrapNode(tree, expr_node, .{
        .unwrap_optional_unwrap = false,
    });

    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const callee_decl_id = self.resolveDeclOfNode(
            doc,
            call.ast.fn_expr,
        ) orelse return null;
        return self.resolveFunctionReturnEnumDecl(callee_decl_id);
    }

    const decl_id = self.resolveDeclOfNode(doc, node) orelse return null;
    return self.resolveDeclEnumType(decl_id);
}

/// Returns enum declaration metadata for a declaration whose value is an enum
/// container declaration.
pub fn enumInfo(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?EnumInfo {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const decl_node = self.decl_store.declAstNode(decl_id) orelse return null;
    const var_decl = tree.fullVarDecl(decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    const init_expr = ast.unwrapNode(tree, init_node, .{});

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    const container_decl = tree.fullContainerDecl(
        &container_decl_buffer,
        init_expr,
    ) orelse return null;
    if (tree.tokenTag(container_decl.ast.main_token) != .keyword_enum) return null;

    const info: EnumInfo = .{
        .file_id = file_id,
        .container_node = init_expr,
        .is_non_exhaustive = self.enumDeclIsNonExhaustive(tree, container_decl),
    };
    return info;
}

/// Resolves a switch case value expression to an enum tag name, including simple
/// aliases such as `const tag = Enum.a; tag`.
pub fn resolveEnumTagNameOfNode(
    self: *LintContext,
    doc: *const LintDocument,
    expr_node: Ast.Node.Index,
) ?[]const u8 {
    const tree = doc.tree(self);
    const node = ast.unwrapNode(tree, expr_node, .{
        .unwrap_optional_unwrap = false,
    });

    // zlinter-disable-next-line require_exhaustive_enum_switch
    return switch (tree.nodeTag(node)) {
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => tag_name: {
            const last_token = tree.lastToken(node);
            if (tree.tokenTag(last_token) != .identifier) break :tag_name null;
            break :tag_name tree.tokenSlice(last_token);
        },
        .identifier => tag_name: {
            const decl_id = self.resolveDeclOfNode(
                doc,
                node,
            ) orelse break :tag_name null;
            break :tag_name self.tagNameFromDeclValue(decl_id);
        },
        else => null,
    };
}

fn resolveFunctionReturnEnumDecl(
    self: *LintContext,
    fn_decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    const file_id = self.decl_store.declFileId(fn_decl_id);
    const tree = self.file_store.fileTree(file_id);
    const node = self.decl_store.declAstNode(fn_decl_id) orelse return null;

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(
        &fn_proto_buffer,
        node,
    ) orelse return null;
    const return_type = fn_proto.ast.return_type.unwrap() orelse return null;
    const return_decl_id = self.decl_store.resolveNodeDecl(
        &self.file_store,
        &self.module_store,
        fn_decl_id,
        return_type,
    ) orelse return null;

    return self.resolveEnumDeclAlias(return_decl_id);
}

fn resolveDeclEnumType(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    if (self.enumInfo(decl_id) != null) return decl_id;

    if (self.resolveDeclTypeDecl(decl_id)) |type_decl_id| {
        if (self.resolveEnumDeclAlias(type_decl_id)) |enum_decl_id|
            return enum_decl_id;
    }

    return self.resolveEnumDeclFromValue(decl_id);
}

fn resolveEnumDeclFromValue(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const decl_node = self.decl_store.declAstNode(decl_id) orelse return null;
    const var_decl = tree.fullVarDecl(decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;

    return self.resolveEnumDeclFromValueExpr(
        decl_id,
        init_node,
    );
}

fn resolveEnumDeclFromValueExpr(
    self: *LintContext,
    context_decl_id: DeclStore.DeclId,
    value_node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const file_id = self.decl_store.declFileId(context_decl_id);
    const tree = self.file_store.fileTree(file_id);
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    if (tree.nodeTag(node) == .field_access) {
        const lhs, _ = tree.nodeData(node).node_and_token;
        const lhs_decl_id = self.decl_store.resolveNodeDecl(
            &self.file_store,
            &self.module_store,
            context_decl_id,
            lhs,
        ) orelse return null;
        return self.resolveEnumDeclAlias(lhs_decl_id);
    }

    const target_decl_id = self.decl_store.resolveNodeDecl(
        &self.file_store,
        &self.module_store,
        context_decl_id,
        node,
    ) orelse return null;
    return self.resolveDeclEnumType(target_decl_id);
}

fn resolveEnumDeclAlias(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    var current_decl_id = decl_id;
    var remaining_alias_depth: u8 = 16;

    while (remaining_alias_depth > 0) : (remaining_alias_depth -= 1) {
        if (self.enumInfo(current_decl_id) != null) return current_decl_id;

        const file_id = self.decl_store.declFileId(current_decl_id);
        const tree = self.file_store.fileTree(file_id);
        const decl_node = self.decl_store.declAstNode(current_decl_id) orelse return null;
        const var_decl = tree.fullVarDecl(decl_node) orelse return null;
        const init_node = var_decl.ast.init_node.unwrap() orelse return null;
        const target_decl_id = self.decl_store.resolveNodeDecl(
            &self.file_store,
            &self.module_store,
            current_decl_id,
            init_node,
        ) orelse return null;

        if (target_decl_id == current_decl_id) return null;
        current_decl_id = target_decl_id;
    }

    return null;
}

fn enumDeclIsNonExhaustive(
    self: *LintContext,
    tree: Ast,
    container_decl: Ast.full.ContainerDecl,
) bool {
    _ = self;
    if (container_decl.ast.members.len == 0) return false;
    const last_member = container_decl.ast.members[container_decl.ast.members.len - 1];
    const tag = enumMemberTagName(tree, last_member) orelse return false;
    return std.mem.eql(u8, tag, "_");
}

fn tagNameFromDeclValue(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?[]const u8 {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const decl_node = self.decl_store.declAstNode(decl_id) orelse return null;
    const var_decl = tree.fullVarDecl(decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;

    return self.tagNameFromValueExpr(decl_id, init_node);
}

fn tagNameFromValueExpr(
    self: *LintContext,
    context_decl_id: DeclStore.DeclId,
    value_node: Ast.Node.Index,
) ?[]const u8 {
    const file_id = self.decl_store.declFileId(context_decl_id);
    const tree = self.file_store.fileTree(file_id);
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    // zlinter-disable-next-line require_exhaustive_enum_switch
    return switch (tree.nodeTag(node)) {
        .enum_literal => tree.tokenSlice(tree.nodeMainToken(node)),
        .field_access => blk: {
            const last_token = tree.lastToken(node);
            if (tree.tokenTag(last_token) != .identifier) break :blk null;
            break :blk tree.tokenSlice(last_token);
        },
        .identifier => blk: {
            const target_decl_id = self.decl_store.resolveNodeDecl(
                &self.file_store,
                &self.module_store,
                context_decl_id,
                node,
            ) orelse break :blk null;
            break :blk self.tagNameFromDeclValue(target_decl_id);
        },
        else => null,
    };
}

/// Allocates the leading doc comments for a declaration without comment tokens.
pub fn allocDeclDocComments(
    self: *const LintContext,
    allocator: std.mem.Allocator,
    decl_id: DeclStore.DeclId,
) !?[]const u8 {
    const node = self.decl_store.declAstNode(decl_id) orelse return null;
    if (node == .root) return null;

    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const first_token = tree.firstToken(node);
    if (first_token == 0) return null;

    var first_doc_token = first_token;
    while (first_doc_token > 0 and tree.tokenTag(first_doc_token - 1) == .doc_comment) {
        first_doc_token -= 1;
    }
    if (first_doc_token == first_token) return null;

    var comments_text = std.ArrayList(u8).empty;
    errdefer comments_text.deinit(allocator);

    var token = first_doc_token;
    while (token < first_token) : (token += 1) {
        if (token != first_doc_token) try comments_text.append(allocator, '\n');

        const raw = tree.tokenSlice(token);
        const without_marker = if (std.mem.startsWith(u8, raw, "///") or
            std.mem.startsWith(u8, raw, "//!"))
            raw[3..]
        else
            raw;
        try comments_text.appendSlice(allocator, without_marker);
    }

    return try comments_text.toOwnedSlice(allocator);
}

/// Resolves `node` to the declaration it directly names.
///
/// Expression lookup needs a lexical starting point, so this first finds the
/// nearest declaration containing `node` and then resolves from that scope.
fn immediateDeclForNode(
    self: *LintContext,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.immediateDeclForNode");
    defer zone.end();

    const context_scope_id = self.contextScopeForNode(doc, node) orelse return null;

    return self.decl_store.resolveNodeDeclFromScope(
        &self.file_store,
        &self.module_store,
        doc.file_id,
        context_scope_id,
        node,
    );
}

/// Finds the innermost lexical scope that contains `node`.
///
/// Scope ownership is recorded by `DeclStore` while walking the AST. Use
/// document lineage here instead of token positions so local variables and
/// function parameters resolve from their actual block/function scope.
fn contextScopeForNode(
    self: *const LintContext,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?DeclStore.ScopeId {
    const zone = tracy.traceNamed(@src(), "LintContext.contextScopeForNode");
    defer zone.end();

    var current: ?Ast.Node.Index = node;
    while (current) |current_node| {
        if (self.decl_store.scopeByNode(doc.file_id, current_node)) |scope_id| {
            return scope_id;
        }

        current = doc.lineage.items(.parent)[@intFromEnum(current_node)];
    }
    return self.decl_store.scopeByNode(doc.file_id, .root);
}

pub fn resolveDeclValueKind(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?TypeStore.Type {
    return self.resolveDeclValueKindDepth(decl_id, 16);
}

fn resolveDeclValueKindDepth(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
    remaining_depth: u8,
) ?TypeStore.Type {
    if (remaining_depth == 0) return null;

    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const node = self.decl_store.declAstNode(decl_id) orelse return null;

    if (node == .root) {
        return if (ast.isRootImplicitStruct(tree)) .struct_type else .namespace_type;
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return TypeStore.summarizeFnProto(
            tree,
            fn_proto,
            false,
        ).coarseType();
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap();
        if (var_decl.ast.type_node.unwrap()) |type_node| {
            if (typeKindFromValueTypeNode(tree, type_node)) |kind| {
                return kind;
            }

            return .other;
        }

        if (init_node) |value_node| {
            return self.typeKindFromValueNode(
                decl_id,
                value_node,
                remaining_depth - 1,
            );
        }
    }

    if (tree.fullContainerField(node)) |container_field| {
        const value_node = container_field.ast.value_expr.unwrap();
        if (container_field.ast.type_expr.unwrap()) |type_node| {
            if (typeKindFromValueTypeNode(tree, type_node)) |kind| {
                return kind;
            }

            return .other;
        }

        if (value_node) |expr| {
            return self.typeKindFromValueNode(
                decl_id,
                expr,
                remaining_depth - 1,
            );
        }
    }

    return null;
}

fn resolveDeclTypeKindDepth(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
    remaining_depth: u8,
) ?TypeStore.Type {
    if (remaining_depth == 0) return null;

    if (self.decl_store.declResolvedType(decl_id)) |type_id| {
        const kind = self.type_store.summary(type_id).coarseType();
        switch (kind) {
            .unknown, .other, .primitive => {},
            else => return kind,
        }
    }

    if (self.declResolvedTypeTarget(decl_id)) |target| {
        if (self.typeKindFromTarget(
            target,
            remaining_depth - 1,
        )) |kind| return kind;
    }

    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const node = self.decl_store.declAstNode(decl_id) orelse return null;

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return TypeStore.summarizeFnProto(
            tree,
            fn_proto,
            false,
        ).coarseType();
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.type_node.unwrap()) |type_node| {
            if (typeKindFromTypeNode(tree, type_node)) |kind| return kind;
        }

        if (var_decl.ast.init_node.unwrap()) |init_node| {
            return self.typeKindFromValueNode(
                decl_id,
                init_node,
                remaining_depth - 1,
            );
        }
    }

    if (tree.fullContainerField(node)) |container_field| {
        if (container_field.ast.type_expr.unwrap()) |type_node| {
            if (typeKindFromTypeNode(tree, type_node)) |kind| return kind;
        }

        if (container_field.ast.value_expr.unwrap()) |value_node| {
            return self.typeKindFromValueNode(
                decl_id,
                value_node,
                remaining_depth - 1,
            );
        }
    }

    return null;
}

fn typeKindFromTarget(
    self: *LintContext,
    target: DeclStore.TypeTarget,
    remaining_depth: u8,
) ?TypeStore.Type {
    return switch (target) {
        .decl => |decl_id| self.resolveDeclTypeKindDepth(
            decl_id,
            remaining_depth,
        ),
        .container => |container| blk: {
            const tree = self.file_store.fileTree(container.file_id);
            if (@intFromEnum(container.node) >= tree.nodes.len) break :blk null;

            var buffer: [2]Ast.Node.Index = undefined;
            const container_decl = tree.fullContainerDecl(
                &buffer,
                container.node,
            ) orelse break :blk null;

            break :blk containerDeclTypeKind(tree, container_decl);
        },
    };
}

fn typeKindFromTypeNode(
    tree: Ast,
    type_node: Ast.Node.Index,
) ?TypeStore.Type {
    const summary = TypeStore.summarizeTypeNode(
        tree,
        type_node,
    );

    return switch (summary) {
        .unknown, .primitive => null,
        inline else => |_, tag| tag,
    };
}

fn typeKindFromValueTypeNode(
    tree: Ast,
    type_node: Ast.Node.Index,
) ?TypeStore.Type {
    return switch (typeKindFromTypeNode(tree, type_node) orelse return null) {
        .type,
        .@"fn",
        .fn_returns_type,
        => |kind| kind,
        else => null,
    };
}

fn typeKindFromValueNode(
    self: *LintContext,
    context_decl_id: DeclStore.DeclId,
    value_node: Ast.Node.Index,
    remaining_depth: u8,
) ?TypeStore.Type {
    if (remaining_depth == 0) return null;

    const tree = self.file_store.fileTree(
        self.decl_store.declFileId(context_decl_id),
    );
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    if (isImportBuiltinCall(tree, node)) {
        const target_decl_id = self.resolveImportRootDecl(
            self.decl_store.declFileId(context_decl_id),
            node,
        ) orelse return null;

        return self.resolveDeclValueKindDepth(
            target_decl_id,
            remaining_depth - 1,
        );
    }

    const summary = TypeStore.summarizeValueNode(
        tree,
        value_node,
    ) orelse return null;

    switch (summary) {
        .unknown => {},
        .primitive => return .other,
        inline else => |_, tag| return tag,
    }

    if (valueExprIsTypeInfoProjection(tree, node)) return .type;

    if (typeKindFromTypeValueExpr(tree, node)) |kind| return kind;

    var struct_init_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
        if (struct_init.ast.type_expr.unwrap()) |type_expr| {
            if (typeKindFromTypeNode(tree, type_expr)) |kind| return kind;
        }
    }

    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const callee_decl_id = self.decl_store.resolveNodeDecl(
            &self.file_store,
            &self.module_store,
            context_decl_id,
            call.ast.fn_expr,
        ) orelse return null;
        if (self.resolveDeclTypeKindDepth(
            callee_decl_id,
            remaining_depth - 1,
        ) == .fn_returns_type) return .type;
    }

    if (tree.nodeTag(node) == .address_of) {
        const target_node = tree.nodeData(node).node;
        const target_decl_id = self.decl_store.resolveNodeDecl(
            &self.file_store,
            &self.module_store,
            context_decl_id,
            target_node,
        ) orelse return null;

        return self.resolveDeclValueKindDepth(
            target_decl_id,
            remaining_depth - 1,
        );
    }

    const target_decl_id = self.decl_store.resolveNodeDecl(
        &self.file_store,
        &self.module_store,
        context_decl_id,
        node,
    ) orelse return null;

    return self.resolveDeclValueKindDepth(
        target_decl_id,
        remaining_depth - 1,
    );
}

fn isImportBuiltinCall(tree: Ast, node: Ast.Node.Index) bool {
    return switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => std.mem.eql(
            u8,
            tree.tokenSlice(tree.nodeMainToken(node)),
            "@import",
        ),
        else => false,
    };
}

fn resolveImportRootDecl(
    self: *LintContext,
    parent_file_id: FileStore.FileId,
    node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const tree = self.file_store.fileTree(parent_file_id);

    var import_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const import_path = writeImportPath(
        tree,
        node,
        &import_path_buffer,
    ) orelse return null;

    const parent_abs_path = self.file_store.fileAbsPath(parent_file_id);
    const parent_file_dir = std.fs.path.dirname(parent_abs_path) orelse ".";

    const maybe_file_id: ?FileStore.FileId = switch (files.Import.Kind.init(import_path)) {
        .relative => self.file_store.resolve(
            import_path,
            self.io,
            self.gpa,
            parent_file_dir,
        ) catch return null,
        .stdlib => self.file_store.resolveStdLib(
            self.io,
            self.gpa,
            self.zig_lib_directory,
        ) catch return null,
        .builtin => null,
        .root => null,
        .module => id: {
            const parent_module_id = self.module_store.moduleForRootFile(parent_file_id) orelse break :id null;
            const imported_module_id = self.module_store.namedImport(
                parent_module_id,
                import_path,
            ) orelse break :id null;
            break :id self.module_store.rootFile(imported_module_id);
        },
    };

    const file_id = maybe_file_id orelse return null;
    _ = self.decl_store.store(file_id, &self.file_store, self.gpa);
    return self.decl_store.rootDecl(file_id);
}

fn writeImportPath(
    tree: Ast,
    node: Ast.Node.Index,
    buffer: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    switch (tree.nodeTag(node)) {
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => {},
        else => return null,
    }

    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;

    var params_buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&params_buffer, node) orelse return null;
    if (params.len != 1) return null;

    const import_arg = params[0];
    if (tree.nodeTag(import_arg) != .string_literal) return null;

    const raw_import = tree.tokenSlice(tree.nodeMainToken(import_arg));
    var writer: std.Io.Writer = .fixed(buffer);

    return switch (std.zig.string_literal.parseWrite(&writer, raw_import) catch return null) {
        .success => path: {
            writer.flush() catch return null;
            break :path writer.buffer[0..writer.end];
        },
        .failure => null,
    };
}

fn typeKindFromTypeValueExpr(
    tree: Ast,
    node: Ast.Node.Index,
) ?TypeStore.Type {
    const summary = TypeStore.summarizeTypeNode(
        tree,
        node,
    );
    return switch (summary) {
        .unknown => null,
        .primitive => .type,
        inline else => |_, tag| tag,
    };
}

fn valueExprIsTypeInfoProjection(
    tree: Ast,
    node: Ast.Node.Index,
) bool {
    const tag = tree.nodeTag(node);
    switch (tag) {
        .unwrap_optional => {
            const target_node = tree.nodeData(node).node_and_token[0];
            return valueExprIsTypeInfoProjection(tree, target_node);
        },
        .field_access => {
            const target_node, _ = tree.nodeData(node).node_and_token;
            return valueExprIsTypeInfoProjection(tree, target_node);
        },
        .builtin_call,
        .builtin_call_comma,
        .builtin_call_two,
        .builtin_call_two_comma,
        => return std.mem.eql(
            u8,
            tree.tokenSlice(tree.nodeMainToken(node)),
            "@typeInfo",
        ),
        else => return false,
    }
}

fn containerDeclTypeKind(
    tree: Ast,
    container_decl: Ast.full.ContainerDecl,
) TypeStore.Type {
    return switch (tree.tokenTag(container_decl.ast.main_token)) {
        .keyword_struct => if (ast.isContainerNamespace(
            tree,
            container_decl,
        )) .namespace_type else .struct_type,
        .keyword_union => .union_type,
        .keyword_enum => .enum_type,
        .keyword_opaque => .opaque_type,
        else => .other,
    };
}

/// Resolves the declaration of a function from a function call.
///
/// If the given node is not a function call this method will return null.
fn resolveFnDecl(
    self: *LintContext,
    handle: *zls.DocumentStore.Handle,
    call_node: Ast.Node.Index,
    arena: std.mem.Allocator,
) !?zls.Analyser.DeclWithHandle {
    // Return null if not even a function call node.
    var call_buffer: [1]Ast.Node.Index = undefined;
    const call = handle.tree.fullCall(&call_buffer, call_node) orelse
        return null;

    // Walk down symbols until we reach a function.
    var child: zls.Analyser.DeclWithHandle = (try self.resolveDecl(
        handle,
        call.ast.fn_expr,
        arena,
    )) orelse return null;

    walking: while (true) {
        if (child.decl != .ast_node) break :walking;

        if (child.handle.tree.fullVarDecl(child.decl.ast_node)) |decl| {
            if (decl.ast.init_node.unwrap()) |init_node| {
                child = try self.resolveDecl(
                    child.handle,
                    init_node,
                    arena,
                ) orelse break :walking;
                continue :walking;
            }
            break :walking;
        }

        const is_fn_proto = switch (child.handle.tree.nodeTag(child.decl.ast_node)) {
            .fn_proto,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto_simple,
            .fn_decl,
            => true,
            else => false,
        };
        if (is_fn_proto)
            return child
        else
            break :walking;
    }
    return null;
}

/// Resolves the declaration for a given node (aka symbol).
///
/// Only supports identifiers and field access ending in an identifier.
fn resolveDecl(
    self: *LintContext,
    handle: *zls.DocumentStore.Handle,
    node: Ast.Node.Index,
    arena: std.mem.Allocator,
) !?zls.Analyser.DeclWithHandle {
    const tree = handle.tree;

    return switch (tree.nodeTag(node)) {
        .identifier => try self.deprecated.analyser.lookupSymbolGlobal(
            handle,
            tree.getNodeSource(node),
            tree.tokenStart(tree.firstToken(node)),
        ),
        .field_access => field_access: {
            const first_token = tree.firstToken(node);
            const last_token = tree.lastToken(node);

            const held_loc: std.zig.Token.Loc = .{
                .start = tree.tokenStart(first_token),
                .end = tree.tokenStart(last_token) + tree.tokenSlice(last_token).len,
            };

            const identifier_token = last_token;
            if (tree.tokenTag(identifier_token) != .identifier)
                break :field_access null;

            if (try self.deprecated.analyser.getSymbolFieldAccesses(
                arena,
                handle,
                tree.tokenStart(identifier_token),
                held_loc,
                tree.tokenSlice(identifier_token),
            )) |decls| {
                if (decls.len > 0) break :field_access decls[0];
            }
            break :field_access null;
        },
        else => symbol: {
            std.log.warn("Unhandled: {}", .{tree.nodeTag(node)});
            break :symbol null;
        },
    };
}

test "LintContext.resolveTypeKind" {
    // TODO: #149 - bring this test back
    if (true)
        return error.SkipZigTest;

    const TestCase = struct {
        contents: [:0]const u8,
        kind: ?TypeStore.Type,
    };

    for ([_]TestCase{
        // Other:
        // ------
        .{
            .contents = "var ok:u32 = 10;",
            .kind = .other,
        },
        .{
            .contents = "age:u8 = 10,",
            .kind = .other,
        },
        .{
            .contents = "name :[] const u8,",
            .kind = .other,
        },
        // Type:
        // -----
        .{
            .contents = "const A: type = u32;",
            .kind = .type,
        },
        .{
            .contents = "const A = u32;",
            .kind = .type,
        },
        .{
            .contents = "const A:?type = u32;",
            .kind = .type,
        },
        .{
            .contents = "const A:?type = null;",
            .kind = .type,
        },
        .{
            .contents = "const A = @TypeOf(u32);",
            .kind = .type,
        },
        .{
            .contents =
            \\const A = BuildType();
            \\fn BuildType() type {
            \\   return u32;
            \\}
            ,
            .kind = .type,
        },
        .{
            .contents =
            \\const FloatType = IntToFloatType(u32);
            \\fn IntToFloatType(IntType: type) type {
            \\return @Type(.{
            \\    .int = .{
            \\        .signedness = .signed,
            \\        .bits = @typeInfo(IntType).float.bits,
            \\    },
            \\});
            \\}
            ,
            .kind = .type,
        },
        // Struct type:
        // ------------
        .{
            .contents =
            \\const A = BuildType();
            \\fn BuildType() type {
            \\   return struct { field: u32 };
            \\}
            ,
            .kind = .struct_type,
        },
        .{
            .contents = "const A = struct { field: u32 };",
            .kind = .struct_type,
        },
        // Namespace type:
        // ---------------
        .{
            .contents = "const a = struct { const decl: u32 = 1; };",
            .kind = .namespace_type,
        },
        .{
            .contents =
            \\const a = struct {
            \\   pub fn hello() []const u8 {
            \\      return "Hello";
            \\   }
            \\};
            ,
            .kind = .namespace_type,
        },
        // Namespace instance (invalid use)
        // --------------------------------
        .{
            .contents =
            \\ const pointless = my_namespace{};
            \\ const my_namespace = struct { const decl: u32 = 1; };
            ,
            .kind = null,
        },
        // Function:
        // ---------------
        .{
            .contents = "var a: fn () void = undefined;",
            .kind = .@"fn",
        },
        .{
            .contents =
            \\var a = &func;
            \\fn func() u32 {
            \\  return 10;
            \\}
            ,
            .kind = .@"fn",
        },
        // Type that is function
        .{
            .contents = "var a = fn() void;",
            .kind = .fn_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = fn() void;
            ,
            .kind = .fn_type,
        },
        .{
            .contents = "var a = *const fn() void;",
            .kind = .fn_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = *const fn() void;
            ,
            .kind = .fn_type,
        },
        // Type that is function that returns type
        .{
            .contents = "var a = fn() type;",
            .kind = .fn_type_returns_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = fn() type;
            ,
            .kind = .fn_type_returns_type,
        },
        .{
            .contents = "var a = *const fn() type;",
            .kind = .fn_type_returns_type,
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = *const fn() type;
            ,
            .kind = .fn_type_returns_type,
        },
        // Function that returns type
        .{
            .contents =
            \\var a = &func;
            \\fn func() type {
            \\  return f32;
            \\}
            ,
            .kind = .fn_returns_type,
        },
        .{
            .contents =
            \\var a: *const fn () type = undefined;
            ,
            .kind = .fn_returns_type,
        },
        // Error type
        .{
            .contents =
            \\var MyError = error {a,b,c};
            ,
            .kind = .error_type,
        },
        .{
            .contents =
            \\var MyError = some.other.errors || OtherErrors;
            ,
            .kind = .error_type,
        },
        .{
            .contents =
            \\var MyError = Reference;
            \\const Reference = error {a,b,c};
            ,
            .kind = .error_type,
        },
        // Error instance
        .{
            .contents =
            \\const err = error.MyError;
            ,
            .kind = .other,
        },
        .{
            .contents =
            \\var MyError:error{a} = other;
            ,
            .kind = .other,
        },
        // Union instance:
        .{
            .contents =
            \\const u = U{.a=1};
            \\const U = union { a: u32, b: f32 };
            ,
            .kind = .union_instance,
        },
        .{
            .contents =
            \\const a = u;
            \\const u = U{.a=1};
            \\const U = union { a: u32, b: f32 };
            ,
            .kind = .union_instance,
        },
        // Struct instance:
        .{
            .contents =
            \\const s = S{.a=1};
            \\const S = struct { a: u32  };
            ,
            .kind = .struct_instance,
        },
        .{
            .contents =
            \\const a = s;
            \\const s = S{.a=1};
            \\const S = struct { a: u32 };
            ,
            .kind = .struct_instance,
        },
        // Struct instance:
        .{
            .contents =
            \\const s = E.a;
            \\const E = enum { a, b  };
            ,
            .kind = .enum_instance,
        },
        .{
            .contents =
            \\const a = s;
            \\const s = E.a;
            \\const E = enum { a, b };
            ,
            .kind = .enum_instance,
        },
        // Opaque type
        .{
            .contents =
            \\const Window = opaque {
            \\  fn show(self: *Window) void {
            \\    show_window(self);
            \\  }
            \\};
            \\
            \\extern fn show_window(*Window) callconv(.C) void;
            ,
            .kind = .opaque_type,
        },
        // Opaque instance
        .{
            .contents =
            \\var main_window: *Window = undefined;
            \\const Window = opaque {
            \\  fn show(self: *Window) void {
            \\    show_window(self);
            \\  }
            \\};
            \\
            \\extern fn show_window(*Window) callconv(.C) void;
            ,
            .kind = .other,
        },
    }) |test_case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var context = testing.initFakeContext(std.testing.allocator, arena.allocator(), std.testing.io);
        defer context.deinit();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &context,
            tmp.dir,
            "test.zig",
            test_case.contents,
            arena.allocator(),
        );
        std.testing.expectEqual(doc.tree(&context).errors.len, 0) catch |err| {
            std.debug.print("Failed to parse AST:\n{s}\n", .{test_case.contents});
            for (doc.tree(&context).errors) |ast_err| {
                var buffer: [1024]u8 = undefined;

                var writer = std.Io.File.stderr().writer(std.testing.io, &buffer).interface;
                try doc.tree(&context).renderError(ast_err, &writer);
                try writer.flush();
            }
            return err;
        };

        const node = doc.tree(&context).rootDecls()[0];
        const actual_kind = if (doc.tree(&context).fullVarDecl(node)) |var_decl|
            try context.resolveTypeKindDeprecated(doc, .{ .var_decl = var_decl })
        else if (doc.tree(&context).fullContainerField(node)) |container_field|
            try context.resolveTypeKindDeprecated(doc, .{ .container_field = container_field })
        else
            @panic("Fail");

        std.testing.expectEqual(test_case.kind, actual_kind) catch |e| {
            const border: [50]u8 = @splat('-');
            std.debug.print("Node:\n{s}\n{s}\n{s}\n", .{ border, doc.tree(&context).getNodeSource(node), border });
            std.debug.print("Expected: {any}\n", .{test_case.kind});
            std.debug.print("Actual: {any}\n", .{actual_kind});
            std.debug.print("Contents:\n{s}\n{s}\n{s}\n", .{ border, test_case.contents, border });

            return e;
        };
    }
}

const ast = @import("../ast.zig");
const builtin = @import("builtin");
const comments = @import("../comments.zig");
const files = @import("../files.zig");
const std = @import("std");
const testing = @import("../testing.zig");
const tracy = @import("tracy");
const zls = @import("zls");
const BuildConfigStore = @import("BuildConfigStore.zig");
const CompileContext = @import("CompileContext.zig");
const DeclStore = @import("DeclStore.zig");
const FileStore = @import("FileStore.zig");
const LintDocument = @import("LintDocument.zig");
const ModuleStore = @import("ModuleStore.zig");
const TypeStore = @import("TypeStore.zig");
const Ast = std.zig.Ast;

test {
    refAllDeclsExcept(@This(), &.{});
}

fn refAllDeclsExcept(comptime T: type, comptime excluded_declarations: []const []const u8) void {
    if (!builtin.is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl_name| {
        comptime {
            for (excluded_declarations) |excluded_declaration| {
                if (std.mem.eql(u8, decl_name, excluded_declaration)) break;
            } else {
                _ = &@field(T, decl_name);
            }
        }
    }
}
