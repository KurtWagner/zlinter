//! The context of all document and rule executions. It'll live the duration
//! of linting all zig source files.
const LintContext = @This();

io: std.Io,

/// Externally owned slice to zig executable path
zig_exe: []const u8,

/// Externally owned slice to zig lib directory path
zig_lib_directory: []const u8,

/// Externally owned slice to current working directory
cwd: []const u8,

/// Lives for the full linter invocation.
session_arena: std.mem.Allocator,
compile_contexts: std.MultiArrayList(CompileContext) = .empty,
compile_context_ids_by_file: std.AutoHashMapUnmanaged(FileStore.FileId, std.ArrayList(CompileContext.Id)) = .empty,
compile_file_index_built: bool = false,
file_store: FileStore,
module_store: ModuleStore,
decl_store: DeclStore,
type_store: TypeStore,
build_config_store: BuildConfigStore,
focused_compiled_contexts: std.AutoHashMapUnmanaged(CompileContext.Id, void) = .empty,
/// Root source file for the active compile context, when known.
compile_root_file_id: ?FileStore.FileId = null,

pub fn init(self: *LintContext, focus_compiled_names: ?[]const []const u8) !void {
    const zone = tracy.traceNamed(@src(), "LintContext.init");
    defer zone.end();

    // Maybe one day we will care enough to use a fake for tests but for now
    // it's fine to ignore...
    if (!builtin.is_test) {
        const config_id = try self.initBuildConfig(); // populated compile contexts
        const build_config = self.build_config_store.buildConfig(config_id);

        if (focus_compiled_names) |l| {
            for (l) |focus_compiled_name| {
                const maybe_focus_id: ?CompileContext.Id = focus_id: {
                    for (0..self.compile_contexts.len) |i| {
                        const name = self.compile_contexts
                            .get(i)
                            .stepName(build_config);
                        if (std.mem.eql(u8, name, focus_compiled_name))
                            break :focus_id .fromIndex(i);
                    }
                    break :focus_id null;
                };
                if (maybe_focus_id) |focus_id|
                    oom(self.focused_compiled_contexts.put(
                        self.session_arena,
                        focus_id,
                        {},
                    ))
                else
                    std.log.err("Could not find compiled unit: '{s}'", .{focus_compiled_name});
            }
        } else if (selectedCompilePriority(build_config)) |selected_priority| {
            for (0..self.compile_contexts.len) |i| {
                const kind = self.compile_contexts
                    .get(i)
                    .stepKind(build_config);

                if (compilePriority(kind) == selected_priority) {
                    oom(self.focused_compiled_contexts.put(
                        self.session_arena,
                        .fromIndex(i),
                        {},
                    ));
                }
            }
        }
    }
}

fn initBuildConfig(self: *LintContext) !BuildConfigStore.ConfigId {
    const zone = tracy.traceNamed(@src(), "LintContext.initBuildConfig");
    defer zone.end();

    const config_id = try self.build_config_store.resolve(
        self.io,
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
    return config_id;
}

fn selectedCompilePriority(build_config: *const std.Build.Configuration) ?CompilePriority {
    var selected_priority: ?CompilePriority = null;

    for (build_config.steps) |step| {
        const compile = step.extended.cast(
            build_config,
            std.Build.Configuration.Step.Compile,
        ) orelse continue;

        const priority = compilePriority(compile.flags3.kind);
        if (selected_priority == null or
            @intFromEnum(priority) < @intFromEnum(selected_priority.?))
            selected_priority = priority;
    }

    return selected_priority;
}

fn compilePriority(kind: std.Build.Configuration.Step.Compile.Kind) CompilePriority {
    return switch (kind) {
        .exe => .exe,
        .lib => .lib,
        .obj => .obj,
        .@"test", .test_obj => .@"test",
    };
}

/// When no compiled units are provided by the user we look at all from the build
/// configuration in this order. e.g., if there's an exe, we only use exe's.
const CompilePriority = enum(u3) {
    exe = 0,
    lib = 1,
    obj = 2,
    @"test" = 3,
};

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

    self.compile_contexts.append(self.session_arena, .{
        .step_index = step_index,
        .root_module = root_module_id,
    }) catch unreachable;
}

fn resolveBuildModule(
    self: *LintContext,
    config_id: BuildConfigStore.ConfigId,
    build_module_index: std.Build.Configuration.Module.Index,
) !?ModuleStore.ModuleId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveBuildModule");
    defer zone.end();

    const build_config = self.build_config_store.buildConfig(config_id);

    var module_id_by_build_module_index: std.AutoHashMapUnmanaged(
        std.Build.Configuration.Module.Index,
        ModuleStore.ModuleId,
    ) = .empty;
    defer module_id_by_build_module_index.deinit(self.session_arena);

    var queue: std.ArrayList(std.Build.Configuration.Module.Index) = .empty;
    defer queue.deinit(self.session_arena);

    const root_module_id = try self.resolveBuildModuleShallow(
        config_id,
        build_module_index,
    ) orelse return null;

    module_id_by_build_module_index.put(self.session_arena, build_module_index, root_module_id) catch unreachable;
    queue.append(self.session_arena, build_module_index) catch unreachable;

    while (queue.pop()) |current_build_module_index| {
        const current_module_id = module_id_by_build_module_index.get(current_build_module_index).?;

        // This exact build module may already have been populated by an earlier compile step.
        if (self.module_store.moduleIdsByImportName(current_module_id).count() != 0) {
            continue;
        }

        const build_module = current_build_module_index.get(build_config);

        const imports = build_module.import_table.get(build_config).imports.mal;
        var module_id_by_import_name: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;

        module_id_by_import_name.ensureTotalCapacity(self.session_arena, @intCast(imports.len)) catch unreachable;
        for (imports.items(.name), imports.items(.module)) |
            build_import_name_id,
            build_import_module_index,
        | {
            const import_name_slice = build_import_name_id.slice(build_config);

            const import_module_id = module_id_by_build_module_index.get(build_import_module_index) orelse child: {
                const resolved = (try self.resolveBuildModuleShallow(
                    config_id,
                    build_import_module_index,
                )) orelse continue;

                module_id_by_build_module_index.put(self.session_arena, build_import_module_index, resolved) catch unreachable;
                queue.append(self.session_arena, build_import_module_index) catch unreachable;

                break :child resolved;
            };

            module_id_by_import_name.putAssumeCapacity(
                self.session_arena.dupe(u8, import_name_slice) catch unreachable,
                import_module_id,
            );
        }

        self.module_store.modules.items(.module_id_by_import_name)[current_module_id.toIndex()] = module_id_by_import_name;
        module_id_by_import_name = .empty;
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
        self.session_arena,
        build_root_path,
    ) orelse return null;
    defer self.session_arena.free(root_path);

    return self.module_store.resolve(.{
        .root_file = try self.file_store.resolve(
            root_path,
            self.io,
            self.cwd,
        ),
        .build_config = config_id,
        .build_config_module = build_module_index,
        .module_id_by_import_name = .empty,
    });
}

pub fn resolveFile(self: *LintContext, input_path: []const u8) !FileStore.FileId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveFile");
    defer zone.end();

    const id = try self.file_store.resolve(
        input_path,
        self.io,
        self.cwd,
    );
    self.decl_store.resolveFileTypes(
        id,
        &self.file_store,
        &self.module_store,
        &self.type_store,
    );
    return id;
}

pub fn resolveFileTypes(self: *LintContext, file_id: FileStore.FileId) void {
    self.decl_store.resolveFileTypes(
        file_id,
        &self.file_store,
        &self.module_store,
        &self.type_store,
    );
}

// TODO: #149 - avoid this shared state and instead pass through
pub fn setCompileRootFileId(self: *LintContext, compile_root_file_id: ?FileStore.FileId) void {
    self.compile_root_file_id = compile_root_file_id;
    self.decl_store.compile_root_file_id = compile_root_file_id;
}

pub fn compileRootFileId(
    self: *const LintContext,
    compile_context_id: CompileContext.Id,
) FileStore.FileId {
    return self.module_store.rootFileId(
        self.compile_contexts.items(.root_module)[compile_context_id.toIndex()],
    );
}

pub fn compileContextIdsForFile(
    self: *LintContext,
    file_id: FileStore.FileId,
    gpa: std.mem.Allocator,
) ![]CompileContext.Id {
    self.ensureCompileContextIdsByFile(gpa);

    const cached = self.compile_context_ids_by_file.get(file_id) orelse
        return gpa.dupe(CompileContext.Id, &.{});

    return gpa.dupe(CompileContext.Id, cached.items);
}

fn ensureCompileContextIdsByFile(
    self: *LintContext,
    gpa: std.mem.Allocator,
) void {
    if (self.compile_file_index_built) return;

    for (0..self.compile_contexts.len) |index| {
        const compile_context_id: CompileContext.Id = .fromIndex(index);
        self.indexCompileContextFiles(compile_context_id, gpa);
    }

    self.compile_file_index_built = true;
}

fn appendCompileContextForFile(
    self: *LintContext,
    file_id: FileStore.FileId,
    compile_context_id: CompileContext.Id,
) void {
    const entry = oom(self.compile_context_ids_by_file.getOrPut(
        self.session_arena,
        file_id,
    ));
    if (!entry.found_existing)
        entry.value_ptr.* = .empty;

    oom(entry.value_ptr.append(self.session_arena, compile_context_id));
}

const ReachKey = enum(u64) {
    _,

    fn init(file_id: FileStore.FileId, module_id: ModuleStore.ModuleId) ReachKey {
        return @enumFromInt((@as(u64, @intFromEnum(file_id)) << 32) |
            @as(u64, @intFromEnum(module_id)));
    }
};

const ReachQueueItem = struct {
    file_id: FileStore.FileId,
    module_id: ModuleStore.ModuleId,
};

fn indexCompileContextFiles(
    self: *LintContext,
    compile_context_id: CompileContext.Id,
    gpa: std.mem.Allocator,
) void {
    const root_module_id = self.compile_contexts.items(.root_module)[compile_context_id.toIndex()];
    const compile_root_file_id = self.module_store.rootFileId(root_module_id);

    var visited = std.AutoHashMapUnmanaged(ReachKey, void).empty;
    defer visited.deinit(gpa);

    var indexed_files = std.AutoHashMapUnmanaged(FileStore.FileId, void).empty;
    defer indexed_files.deinit(gpa);

    var queue = std.ArrayList(ReachQueueItem).empty;
    defer queue.deinit(gpa);

    oom(queue.append(gpa, .{
        .file_id = compile_root_file_id,
        .module_id = root_module_id,
    }));

    while (queue.pop()) |item| {
        const key = ReachKey.init(item.file_id, item.module_id);
        const visited_entry = oom(visited.getOrPut(gpa, key));
        if (visited_entry.found_existing) continue;

        const indexed_entry = oom(indexed_files.getOrPut(gpa, item.file_id));
        if (!indexed_entry.found_existing)
            self.appendCompileContextForFile(item.file_id, compile_context_id);

        const tree = self.file_store.fileTree(item.file_id);
        var node_index: u32 = @intFromEnum(Ast.Node.Index.root);
        while (node_index < tree.nodes.len) : (node_index += 1) {
            const node: Ast.Node.Index = @enumFromInt(node_index);

            var import_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
            const import_path = import_utils.writeImportPath(
                tree,
                node,
                &import_path_buffer,
            ) orelse continue;

            const resolved: ?ReachQueueItem = switch (import_utils.Kind.init(import_path)) {
                .relative => relative: {
                    const resolved_file_id = import_utils.resolveFile(
                        &self.file_store,
                        &self.module_store,
                        self.io,
                        self.zig_lib_directory,
                        .{
                            .parent_file_id = item.file_id,
                            .compile_root_file_id = compile_root_file_id,
                        },
                        import_path,
                    ) catch break :relative null;

                    break :relative if (resolved_file_id) |resolved_file|
                        .{
                            .file_id = resolved_file,
                            .module_id = item.module_id,
                        }
                    else
                        null;
                },
                .root => .{
                    .file_id = compile_root_file_id,
                    .module_id = root_module_id,
                },
                .module => module: {
                    const imported_module_id = self.module_store.moduleIdByImportName(
                        item.module_id,
                        import_path,
                    ) orelse break :module null;

                    break :module .{
                        .file_id = self.module_store.rootFileId(imported_module_id),
                        .module_id = imported_module_id,
                    };
                },
                .stdlib,
                .builtin,
                => null,
            };

            const next = resolved orelse continue;
            oom(queue.append(gpa, next));
        }
    }
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

    doc.* = .{
        .file_id = file_id,
        .lineage = .empty,
        .comments = oom(comments.allocParse(source, gpa)),
        .skipper = .init(doc.comments, source, gpa),
    };

    {
        oom(doc.lineage.resize(gpa, tree.nodes.len));
        for (0..tree.nodes.len) |i| {
            doc.lineage.set(i, .{});
        }

        const QueueItem = struct {
            parent: ?Ast.Node.Index = null,
            node: Ast.Node.Index,
        };

        var queue = std.ArrayList(QueueItem).empty;
        defer queue.deinit(gpa);

        oom(queue.append(gpa, .{ .node = .root }));

        while (queue.pop()) |item| {
            const children = oom(ast.nodeChildrenAlloc(
                gpa,
                tree,
                item.node,
            ));

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
                oom(queue.append(gpa, .{
                    .parent = item.node,
                    .node = child,
                }));
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
/// `.instance = .enum` cannot list the enum's tags.
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
    const return_decl_id = self.decl_store.resolveDeclByNode(
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
        const lhs_decl_id = self.decl_store.resolveDeclByNode(
            &self.file_store,
            &self.module_store,
            context_decl_id,
            lhs,
        ) orelse return null;
        return self.resolveEnumDeclAlias(lhs_decl_id);
    }

    const target_decl_id = self.decl_store.resolveDeclByNode(
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
        const target_decl_id = self.decl_store.resolveDeclByNode(
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
            const target_decl_id = self.decl_store.resolveDeclByNode(
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

    var token = first_doc_token;
    while (token < first_token) : (token += 1) {
        if (token != first_doc_token) oom(comments_text.append(allocator, '\n'));

        const raw = tree.tokenSlice(token);
        const without_marker = if (std.mem.startsWith(u8, raw, "///") or
            std.mem.startsWith(u8, raw, "//!"))
            raw[3..]
        else
            raw;
        oom(comments_text.appendSlice(allocator, without_marker));
    }

    return oom(comments_text.toOwnedSlice(allocator));
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

    if (self.decl_store.declIdByNode(doc.file_id, node)) |decl_id| {
        return decl_id;
    }

    const context_scope_id = self.contextScopeForNode(doc, node) orelse return null;

    return self.decl_store.resolveDeclByNodeFromScope(
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
        if (self.decl_store.scopeIdByNode(doc.file_id, current_node)) |scope_id| {
            return scope_id;
        }

        current = doc.lineage.items(.parent)[@intFromEnum(current_node)];
    }
    return self.decl_store.scopeIdByNode(doc.file_id, .root);
}

pub fn resolveDeclValueKind(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?TypeStore.Type {
    return if (self.resolveDeclValueSummary(decl_id)) |summary|
        summary.coarseType()
    else
        null;
}

pub fn resolveDeclValueSummary(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ?TypeStore.TypeSummary {
    return self.resolveDeclValueSummaryDepth(decl_id, 16);
}

fn resolveDeclValueSummaryDepth(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    if (remaining_depth == 0) return null;

    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const node = self.decl_store.declAstNode(decl_id) orelse return null;

    if (node == .root) {
        return .{ .type = .{ .kind = if (ast.isRootImplicitStruct(tree)) .@"struct" else .namespace } };
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return TypeStore.summarizeFnProto(
            tree,
            fn_proto,
            false,
        );
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        const init_node = var_decl.ast.init_node.unwrap();
        if (var_decl.ast.type_node.unwrap()) |type_node| {
            if (typeSummaryFromValueTypeNode(tree, type_node)) |summary| {
                return summary;
            }

            return .other;
        }

        if (init_node) |value_node| {
            return self.typeSummaryFromValueNode(
                decl_id,
                value_node,
                remaining_depth - 1,
            );
        }
    }

    if (tree.fullContainerField(node)) |container_field| {
        const value_node = container_field.ast.value_expr.unwrap();
        if (container_field.ast.type_expr.unwrap()) |type_node| {
            if (typeSummaryFromValueTypeNode(tree, type_node)) |summary| {
                return summary;
            }

            return .other;
        }

        if (value_node) |expr| {
            return self.typeSummaryFromValueNode(
                decl_id,
                expr,
                remaining_depth - 1,
            );
        }
    }

    return null;
}

fn resolveDeclTypeSummaryDepth(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    if (remaining_depth == 0) return null;

    if (self.decl_store.declResolvedType(decl_id)) |type_id| {
        const summary = self.type_store.summary(type_id);
        switch (summary) {
            .unknown, .other, .primitive => {},
            else => return summary,
        }
    }

    if (self.declResolvedTypeTarget(decl_id)) |target| {
        if (self.typeSummaryFromTarget(
            target,
            remaining_depth - 1,
        )) |summary| return summary;
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
        );
    }

    if (tree.fullVarDecl(node)) |var_decl| {
        if (var_decl.ast.type_node.unwrap()) |type_node| {
            if (typeSummaryFromTypeNode(tree, type_node)) |summary| return summary;
        }

        if (var_decl.ast.init_node.unwrap()) |init_node| {
            return self.typeSummaryFromValueNode(
                decl_id,
                init_node,
                remaining_depth - 1,
            );
        }
    }

    if (tree.fullContainerField(node)) |container_field| {
        if (container_field.ast.type_expr.unwrap()) |type_node| {
            if (typeSummaryFromTypeNode(tree, type_node)) |summary| return summary;
        }

        if (container_field.ast.value_expr.unwrap()) |value_node| {
            return self.typeSummaryFromValueNode(
                decl_id,
                value_node,
                remaining_depth - 1,
            );
        }
    }

    return null;
}

fn typeSummaryFromTarget(
    self: *LintContext,
    target: DeclStore.TypeTarget,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    return switch (target) {
        .decl => |decl_id| self.resolveDeclTypeSummaryDepth(
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

            break :blk containerDeclTypeSummary(tree, container_decl);
        },
    };
}

fn typeSummaryFromTypeNode(
    tree: Ast,
    type_node: Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const summary = TypeStore.summarizeTypeNode(
        tree,
        type_node,
    );

    return switch (summary) {
        .unknown, .primitive => null,
        else => summary,
    };
}

fn typeSummaryFromValueTypeNode(
    tree: Ast,
    type_node: Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const summary = typeSummaryFromTypeNode(tree, type_node) orelse return null;
    return switch (summary.coarseType()) {
        .@"fn",
        .fn_returns_type,
        => summary,
        .type => switch (summary.typeValueKind().?) {
            .unknown => summary,
            else => null,
        },
        else => null,
    };
}

fn typeSummaryFromValueNode(
    self: *LintContext,
    context_decl_id: DeclStore.DeclId,
    value_node: Ast.Node.Index,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    if (remaining_depth == 0) return null;

    const tree = self.file_store.fileTree(
        self.decl_store.declFileId(context_decl_id),
    );
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    if (import_utils.isImportBuiltinCall(tree, node)) {
        const target_decl_id = self.resolveImportRootDecl(
            self.decl_store.declFileId(context_decl_id),
            node,
        ) orelse return null;

        return self.resolveDeclValueSummaryDepth(
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
        else => return summary,
    }

    if (valueExprIsTypeInfoProjection(tree, node)) return .{ .type = .unknown };

    if (typeSummaryFromTypeValueExpr(tree, node)) |type_summary| return type_summary;

    var struct_init_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullStructInit(&struct_init_buffer, node)) |struct_init| {
        if (struct_init.ast.type_expr.unwrap()) |type_expr| {
            if (typeSummaryFromTypeNode(tree, type_expr)) |type_summary| return type_summary;
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
        const callee_summary = self.resolveDeclTypeSummaryDepth(
            callee_decl_id,
            remaining_depth - 1,
        ) orelse return null;
        if (callee_summary.coarseType() == .fn_returns_type) {
            if (self.decl_store.resolveTypeFactoryResultTarget(
                &self.file_store,
                &self.module_store,
                callee_decl_id,
            )) |target| {
                return self.typeSummaryFromTarget(target, remaining_depth - 1);
            }
            return .{ .type = .unknown };
        }
    }

    if (tree.nodeTag(node) == .address_of) {
        const target_node = tree.nodeData(node).node;
        const target_decl_id = self.decl_store.resolveNodeDecl(
            &self.file_store,
            &self.module_store,
            context_decl_id,
            target_node,
        ) orelse return null;

        return self.resolveDeclValueSummaryDepth(
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

    return self.resolveDeclValueSummaryDepth(
        target_decl_id,
        remaining_depth - 1,
    );
}

fn resolveImportRootDecl(
    self: *LintContext,
    parent_file_id: FileStore.FileId,
    node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const tree = self.file_store.fileTree(parent_file_id);

    var import_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const import_path = import_utils.writeImportPath(
        tree,
        node,
        &import_path_buffer,
    ) orelse return null;

    const maybe_file_id = import_utils.resolveFile(
        &self.file_store,
        &self.module_store,
        self.io,
        self.zig_lib_directory,
        .{
            .parent_file_id = parent_file_id,
            .compile_root_file_id = self.compile_root_file_id,
        },
        import_path,
    ) catch return null;

    const file_id = maybe_file_id orelse return null;
    self.resolveFileTypes(file_id);
    return self.decl_store.rootDecl(file_id);
}

fn typeSummaryFromTypeValueExpr(
    tree: Ast,
    node: Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const summary = TypeStore.summarizeTypeNode(
        tree,
        node,
    );
    return switch (summary) {
        .unknown => null,
        .primitive => .{ .type = .{ .kind = .primitive } },
        else => summary,
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

fn containerDeclTypeSummary(
    tree: Ast,
    container_decl: Ast.full.ContainerDecl,
) TypeStore.TypeSummary {
    return switch (tree.tokenTag(container_decl.ast.main_token)) {
        .keyword_struct => if (ast.isContainerNamespace(
            tree,
            container_decl,
        )) .{ .type = .{ .kind = .namespace } } else .{ .type = .{ .kind = .@"struct" } },
        .keyword_union => .{ .type = .{ .kind = .@"union" } },
        .keyword_enum => .{ .type = .{ .kind = .@"enum" } },
        .keyword_opaque => .{ .type = .{ .kind = .@"opaque" } },
        else => .other,
    };
}

test "LintContext.resolveTypeKind" {
    const TestCase = struct {
        contents: [:0]const u8,
        summary: TypeStore.TypeSummary,
    };

    var failed = false;
    for ([_]TestCase{
        // Primitive:
        // ------
        .{
            .contents = "var ok:u32 = 10;",
            .summary = .{
                .primitive = .{
                    .number = .{
                        .name = "u32",
                        .kind = .unsigned_int,
                        .bits = 32,
                    },
                },
            },
        },
        .{
            .contents = "age:i16 = 10,",
            .summary = .{
                .primitive = .{
                    .number = .{
                        .name = "i16",
                        .kind = .signed_int,
                        .bits = 16,
                    },
                },
            },
        },
        .{
            .contents = "var flag: bool = true;",
            .summary = .{ .primitive = .bool },
        },
        .{
            .contents = "name :[] const u8,",
            .summary = .{
                .slice = .{
                    .child_type = .{
                        .primitive = .{
                            .number = .{
                                .name = "u8",
                                .kind = .unsigned_int,
                                .bits = 8,
                            },
                        },
                    },
                },
            },
        },
        .{
            .contents = "var arr: [4]u8 = undefined;",
            .summary = .{
                .array = .{
                    .child_type = .{
                        .primitive = .{
                            .number = .{
                                .name = "u8",
                                .kind = .unsigned_int,
                                .bits = 8,
                            },
                        },
                    },
                },
            },
        },
        .{
            .contents = "var ptr: *i32 = undefined;",
            .summary = .{
                .primitive = .{
                    .number = .{
                        .name = "i32",
                        .kind = .signed_int,
                        .bits = 32,
                    },
                },
            },
        },
        .{
            .contents = "var slice: []const u8 = undefined;",
            .summary = .{
                .slice = .{
                    .child_type = .{
                        .primitive = .{
                            .number = .{
                                .name = "u8",
                                .kind = .unsigned_int,
                                .bits = 8,
                            },
                        },
                    },
                },
            },
        },
        .{
            .contents = "var maybe: ?u32 = null;",
            .summary = .{
                .primitive = .{
                    .number = .{
                        .name = "u32",
                        .kind = .unsigned_int,
                        .bits = 32,
                    },
                },
            },
        },
        // Type:
        // -----
        .{
            .contents = "const A: type = u32;",
            .summary = .{ .type = .unknown },
        },
        .{
            .contents = "const A = u32;",
            .summary = .{
                .type = .{ .kind = .primitive },
            },
        },
        .{
            .contents = "const A:?type = u32;",
            .summary = .{ .type = .unknown },
        },
        .{
            .contents = "const A:?type = null;",
            .summary = .{
                .type = .unknown,
            },
        },
        .{
            // TODO: Should we be smart enough to know what type of resolves to?
            // Gets a bit complicated for anything fancy. Probs better waiting
            // for the build server api thing that should give us type info.
            .contents =
            \\const a:@TypeOf(value) = 2;
            \\const value: u32 = 10;
            ,
            .summary = .other,
        },
        .{
            .contents =
            \\const A = BuildType();
            \\fn BuildType() type {
            \\   return u32;
            \\}
            ,
            .summary = .{ .type = .unknown },
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
            .summary = .{ .type = .unknown },
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
            .summary = .{
                .type = .{ .kind = .@"struct" },
            },
        },
        .{
            .contents = "const A = struct { field: u32 };",
            .summary = .{
                .type = .{ .kind = .@"struct" },
            },
        },
        // Namespace type:
        // ---------------
        .{
            .contents = "const a = struct { const decl: u32 = 1; };",
            .summary = .{
                .type = .{ .kind = .namespace },
            },
        },
        .{
            .contents =
            \\const a = struct {
            \\   pub fn hello() []const u8 {
            \\      return "Hello";
            \\   }
            \\};
            ,
            .summary = .{
                .type = .{ .kind = .namespace },
            },
        },
        // Namespace instance (invalid use)
        // --------------------------------
        .{
            .contents =
            \\const pointless = my_namespace{};
            \\const my_namespace = struct { const decl: u32 = 1; };
            ,
            .summary = .{
                .instance = .{ .kind = .@"struct" },
            },
        },
        // Function:
        // ---------------
        .{
            .contents = "var a: fn () void = undefined;",
            .summary = .@"fn",
        },
        .{
            .contents =
            \\var a = &func;
            \\fn func() u32 {
            \\  return 10;
            \\}
            ,
            .summary = .@"fn",
        },
        // Type that is function
        .{
            .contents = "var a = fn() void;",
            .summary = .{
                .type = .{ .kind = .@"fn" },
            },
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = fn() void;
            ,
            .summary = .{
                .type = .{ .kind = .@"fn" },
            },
        },
        .{
            .contents = "var a = *const fn() void;",
            .summary = .{
                .type = .{ .kind = .@"fn" },
            },
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = *const fn() void;
            ,
            .summary = .{
                .type = .{ .kind = .@"fn" },
            },
        },
        // Type that is function that returns type
        .{
            .contents = "var a = fn() type;",
            .summary = .{
                .type = .{ .kind = .fn_returns_type },
            },
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = fn() type;
            ,
            .summary = .{
                .type = .{ .kind = .fn_returns_type },
            },
        },
        .{
            .contents = "var a = *const fn() type;",
            .summary = .{
                .type = .{ .kind = .fn_returns_type },
            },
        },
        .{
            .contents =
            \\const RefFunc = FuncType;
            \\const FuncType = *const fn() type;
            ,
            .summary = .{
                .type = .{ .kind = .fn_returns_type },
            },
        },
        // Function that returns type
        .{
            .contents =
            \\var a = &func;
            \\fn func() type {
            \\  return f32;
            \\}
            ,
            .summary = .fn_returns_type,
        },
        .{
            .contents =
            \\var a: *const fn () type = undefined;
            ,
            .summary = .fn_returns_type,
        },
        // Error type
        .{
            .contents =
            \\var MyError = error {a,b,c};
            ,
            .summary = .{
                .type = .{ .kind = .error_set },
            },
        },
        .{
            .contents =
            \\var MyError = some.other.errors || OtherErrors;
            ,
            .summary = .{
                .type = .{ .kind = .error_set },
            },
        },
        .{
            .contents =
            \\var MyError = Reference;
            \\const Reference = error {a,b,c};
            ,
            .summary = .{
                .type = .{ .kind = .error_set },
            },
        },
        // Error instance
        .{
            .contents =
            \\const err = error.MyError;
            ,
            .summary = .{
                .instance = .{ .kind = .error_set },
            },
        },
        .{
            .contents =
            \\var MyError:error{a} = other;
            ,
            .summary = .{
                .instance = .{ .kind = .error_set },
            },
        },
        // Union instance:
        .{
            .contents =
            \\const u = U{.a=1};
            \\const U = union { a: u32, b: f32 };
            ,
            .summary = .{
                .instance = .{ .kind = .@"union" },
            },
        },
        .{
            .contents =
            \\const a = u;
            \\const u = U{.a=1};
            \\const U = union { a: u32, b: f32 };
            ,
            .summary = .{
                .instance = .{ .kind = .@"union" },
            },
        },
        // Struct instance:
        .{
            .contents =
            \\const s = S{.a=1};
            \\const S = struct { a: u32  };
            ,
            .summary = .{
                .instance = .{ .kind = .@"struct" },
            },
        },
        .{
            .contents =
            \\const a = s;
            \\const s = S{.a=1};
            \\const S = struct { a: u32 };
            ,
            .summary = .{
                .instance = .{ .kind = .@"struct" },
            },
        },
        // Struct instance:
        .{
            .contents =
            \\const s = E.a;
            \\const E = enum { a, b  };
            ,
            .summary = .{
                .instance = .{ .kind = .@"enum" },
            },
        },
        .{
            .contents =
            \\const a = s;
            \\const s = E.a;
            \\const E = enum { a, b };
            ,
            .summary = .{
                .instance = .{ .kind = .@"enum" },
            },
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
            .summary = .{
                .type = .{ .kind = .@"opaque" },
            },
        },
        // Other
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
            .summary = .other,
        },
    }) |test_case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var context = testing.initFakeContext(arena.allocator(), std.testing.io);
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

        const tree = doc.tree(&context);
        const node = tree.rootDecls()[0];

        const maybe_resolved_type = context.resolveTypeOfNode(doc, node);

        if (maybe_resolved_type == null or !TypeStore.TypeSummary.eql(
            maybe_resolved_type.?.summary,
            test_case.summary,
        )) {
            const border: [50]u8 = @splat('-');
            std.debug.print("\n{s}\n{s}\n{s}\n{s}\n", .{
                border,
                border,
                doc.tree(&context).getNodeSource(node),
                border,
            });
            std.debug.print("Expected: {t}\n", .{test_case.summary});
            if (maybe_resolved_type) |resolved_type|
                std.debug.print("Actual: {t}\n", .{resolved_type.summary})
            else
                std.debug.print("Actual: null\n", .{});
            std.debug.print("Contents:\n{s}\n{s}\n{s}\n{s}\n", .{
                border,
                test_case.contents,
                border,
                border,
            });

            failed = true;
        }
    }

    if (failed)
        return error.TestExpectedEqual;
}

// TODO: #149 - add integration tests for root, multiple compile units, modules etc...
test "compileContextIdsForFile includes shared dependency children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.writeFile(tmp.dir, "root1.zig", "const dep = @import(\"dep\");");
    try testing.writeFile(tmp.dir, "root2.zig", "const dep = @import(\"dep\");");
    try tmp.dir.createDirPath(std.testing.io, "dep");
    try testing.writeFile(tmp.dir, "dep/root.zig", "pub const child = @import(\"child.zig\");");
    try testing.writeFile(tmp.dir, "dep/child.zig", "const root = @import(\"root\");");

    var context = testing.initFakeContext(
        arena.allocator(),
        std.testing.io,
    );

    var root1_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root1_path = root1_path_buffer[0..try tmp.dir.realPathFile(
        std.testing.io,
        "root1.zig",
        &root1_path_buffer,
    )];
    var root2_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root2_path = root2_path_buffer[0..try tmp.dir.realPathFile(
        std.testing.io,
        "root2.zig",
        &root2_path_buffer,
    )];
    var dep_root_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dep_root_path = dep_root_path_buffer[0..try tmp.dir.realPathFile(
        std.testing.io,
        "dep/root.zig",
        &dep_root_path_buffer,
    )];
    var dep_child_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dep_child_path = dep_child_path_buffer[0..try tmp.dir.realPathFile(
        std.testing.io,
        "dep/child.zig",
        &dep_child_path_buffer,
    )];

    const root1_file_id = try context.file_store.resolve(root1_path, std.testing.io, ".");
    const root2_file_id = try context.file_store.resolve(root2_path, std.testing.io, ".");
    const dep_root_file_id = try context.file_store.resolve(dep_root_path, std.testing.io, ".");
    const dep_child_file_id = try context.file_store.resolve(dep_child_path, std.testing.io, ".");

    const build_config_id: BuildConfigStore.ConfigId = .fromIndex(0);
    const root1_build_module: std.Build.Configuration.Module.Index = @enumFromInt(0);
    const root2_build_module: std.Build.Configuration.Module.Index = @enumFromInt(1);
    const dep_build_module: std.Build.Configuration.Module.Index = @enumFromInt(2);

    const dep_module_id = context.module_store.resolve(.{
        .root_file = dep_root_file_id,
        .build_config = build_config_id,
        .build_config_module = dep_build_module,
        .module_id_by_import_name = .empty,
    });

    var root1_imports: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;
    try root1_imports.put(
        arena.allocator(),
        try arena.allocator().dupe(u8, "dep"),
        dep_module_id,
    );
    const root1_module_id = context.module_store.resolve(.{
        .root_file = root1_file_id,
        .build_config = build_config_id,
        .build_config_module = root1_build_module,
        .module_id_by_import_name = root1_imports,
    });

    var root2_imports: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;
    try root2_imports.put(
        arena.allocator(),
        try arena.allocator().dupe(u8, "dep"),
        dep_module_id,
    );
    const root2_module_id = context.module_store.resolve(.{
        .root_file = root2_file_id,
        .build_config = build_config_id,
        .build_config_module = root2_build_module,
        .module_id_by_import_name = root2_imports,
    });

    try context.compile_contexts.append(arena.allocator(), .{
        .step_index = @enumFromInt(0),
        .root_module = root1_module_id,
    });
    try context.compile_contexts.append(arena.allocator(), .{
        .step_index = @enumFromInt(1),
        .root_module = root2_module_id,
    });

    const compile_context_ids = try context.compileContextIdsForFile(
        dep_child_file_id,
        arena.allocator(),
    );
    try std.testing.expectEqual(@as(usize, 2), compile_context_ids.len);

    var found_root1 = false;
    var found_root2 = false;
    for (compile_context_ids) |compile_context_id| {
        const compile_root_file_id = context.compileRootFileId(compile_context_id);
        found_root1 = found_root1 or compile_root_file_id == root1_file_id;
        found_root2 = found_root2 or compile_root_file_id == root2_file_id;

        const resolved_root = try import_utils.resolveFile(
            &context.file_store,
            &context.module_store,
            std.testing.io,
            ".",
            .{
                .parent_file_id = dep_child_file_id,
                .compile_root_file_id = compile_root_file_id,
            },
            "root",
        );
        try std.testing.expectEqual(compile_root_file_id, resolved_root.?);
    }
    try std.testing.expect(found_root1);
    try std.testing.expect(found_root2);
}

const ast = @import("../ast.zig");
const builtin = @import("builtin");
const comments = @import("../comments.zig");
const files = @import("../files.zig");
const import_utils = @import("imports.zig");
const std = @import("std");
const testing = @import("../testing.zig");
const tracy = @import("tracy");
const BuildInfo = @import("../BuildInfo.zig");
const BuildConfigStore = @import("BuildConfigStore.zig");
const CompileContext = @import("CompileContext.zig");
const DeclStore = @import("DeclStore.zig");
const FileStore = @import("FileStore.zig");
const LintDocument = @import("LintDocument.zig");
const ModuleStore = @import("ModuleStore.zig");
const PanicAllocator = @import("PanicAllocator.zig");
const TypeStore = @import("TypeStore.zig");
const Ast = std.zig.Ast;
const oom = @import("../allocations.zig").oom;

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
