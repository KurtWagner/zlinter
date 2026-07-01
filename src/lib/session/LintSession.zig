//! The session of all document and rule executions. It'll live the duration
//! of linting all zig source files.
const LintSession = @This();
const LintContext = LintSession;

runtime: *const LintRuntime,

// Stores:
file_store: FileStore,
module_store: ModuleStore,
decl_store: DeclStore,
type_store: TypeStore,
build_config_store: BuildConfigStore,

root_build_config_id: ?BuildConfigStore.ConfigId = null,
compile_contexts: std.MultiArrayList(CompileContext) = .empty,
module_ids_by_file: std.AutoHashMapUnmanaged(FileStore.FileId, std.ArrayList(ModuleStore.ModuleId)) = .empty,
module_file_index_built: bool = false,
resolved_decl_types_by_module: std.AutoHashMapUnmanaged(ResolvedDeclTypeKey, ResolvedDeclType) = .empty,
resolved_decl_by_module_file_node: std.AutoHashMapUnmanaged(ResolvedNodeDeclKey, ?DeclStore.DeclId) = .empty,
decl_cands_by_node: std.AutoHashMapUnmanaged(FileNodeKey, []const DeclCandidate) = .empty,
decl_value_summary_by_module: std.AutoHashMapUnmanaged(ResolvedDeclSummaryKey, ?TypeStore.TypeSummary) = .empty,
decl_summary_cands_by_decl: std.AutoHashMapUnmanaged(DeclStore.DeclId, []const DeclValueSummaryCandidate) = .empty,
type_annotation_cands_by_node: std.AutoHashMapUnmanaged(FileNodeKey, []const ValueTypeAnnotationCandidate) = .empty,

const ResolvedDeclTypeKey = struct {
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
};

const ResolvedDeclSummaryKey = struct {
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
};

const ResolvedNodeDeclKey = enum(u128) {
    _,

    fn init(
        module_id: ModuleStore.ModuleId,
        file_id: FileStore.FileId,
        node: std.zig.Ast.Node.Index,
    ) ResolvedNodeDeclKey {
        return @enumFromInt(
            (@as(u128, @intFromEnum(module_id)) << 64) |
                (@as(u128, @intFromEnum(file_id)) << 32) |
                @as(u128, @intFromEnum(node)),
        );
    }
};

const ResolvedDeclType = struct {
    type_id: ?TypeStore.TypeId,
    type_target: ?DeclStore.TypeTarget,
};

const FileNodeKey = struct {
    file_id: FileStore.FileId,
    node: Ast.Node.Index,
};

const ModuleResolution = struct {
    session: *LintContext,
    module_id: ModuleStore.ModuleId,

    fn context(self: ModuleResolution, parent_file_id: FileStore.FileId) import_utils.ResolveContext {
        return .{
            .file_store = &self.session.file_store,
            .module_store = &self.session.module_store,
            .parent_file_id = parent_file_id,
            .module_id = self.module_id,
            .root_file_id = self.session.module_store.rootFileId(self.module_id),
        };
    }

    fn declContext(self: ModuleResolution, decl_id: DeclStore.DeclId) import_utils.ResolveContext {
        return self.context(self.session.decl_store.declFileId(decl_id));
    }

    fn declType(self: ModuleResolution, decl_id: DeclStore.DeclId) ?TypeStore.TypeSummary {
        return self.session.decl_store.resolveDeclType(
            self.declContext(decl_id),
            decl_id,
        );
    }

    fn declTypeTargetForValue(self: ModuleResolution, decl_id: DeclStore.DeclId) ?DeclStore.TypeTarget {
        return self.session.decl_store.resolveDeclTypeTargetForValue(
            self.declContext(decl_id),
            decl_id,
        );
    }

    fn memberDecl(
        self: ModuleResolution,
        parent_decl_id: DeclStore.DeclId,
        member_name: []const u8,
    ) ?DeclStore.DeclId {
        return self.session.decl_store.resolveMemberDecl(
            self.declContext(parent_decl_id),
            parent_decl_id,
            member_name,
        );
    }

    fn declTypeMember(
        self: ModuleResolution,
        parent_decl_id: DeclStore.DeclId,
        member_name: []const u8,
    ) ?DeclStore.DeclId {
        return self.session.decl_store.resolveDeclTypeMember(
            self.declContext(parent_decl_id),
            parent_decl_id,
            member_name,
        );
    }

    fn declTypeDecl(
        self: ModuleResolution,
        decl_id: DeclStore.DeclId,
    ) ?DeclStore.DeclId {
        return self.session.decl_store.resolveDeclTypeDecl(
            self.declContext(decl_id),
            decl_id,
        );
    }

    fn declByNode(
        self: ModuleResolution,
        context_decl_id: DeclStore.DeclId,
        node: Ast.Node.Index,
    ) ?DeclStore.DeclId {
        return self.session.decl_store.resolveDeclByNode(
            self.declContext(context_decl_id),
            context_decl_id,
            node,
        );
    }

    fn nodeDeclWithRoot(
        self: ModuleResolution,
        context_decl_id: DeclStore.DeclId,
        node: Ast.Node.Index,
    ) ?DeclStore.DeclId {
        return self.session.decl_store.resolveNodeDeclWithRoot(
            self.declContext(context_decl_id),
            context_decl_id,
            node,
        );
    }

    fn declByNodeFromScope(
        self: ModuleResolution,
        file_id: FileStore.FileId,
        scope_id: DeclStore.ScopeId,
        node: Ast.Node.Index,
    ) ?DeclStore.DeclId {
        return self.session.decl_store.resolveDeclByNodeFromScope(
            self.context(file_id),
            file_id,
            scope_id,
            node,
        );
    }

    fn typeFactoryResultTarget(
        self: ModuleResolution,
        fn_decl_id: DeclStore.DeclId,
    ) ?DeclStore.TypeTarget {
        return self.session.decl_store.resolveTypeFactoryResultTarget(
            self.declContext(fn_decl_id),
            fn_decl_id,
        );
    }
};

pub fn init(self: *LintContext, build_info: BuildInfo) !void {
    const zone = tracy.traceNamed(@src(), "LintContext.init");
    defer zone.end();

    // Maybe one day we will care enough to use a fake for tests but for now
    // it's fine to ignore...
    self.root_build_config_id = if (!builtin.is_test)
        try self.initBuildConfig(build_info)
    else
        null;
}

fn initBuildConfig(
    self: *LintContext,
    build_info: BuildInfo,
) !BuildConfigStore.ConfigId {
    const zone = tracy.traceNamed(@src(), "LintContext.initBuildConfig");
    defer zone.end();

    const config_id = try self.build_config_store.resolve(".");

    const compile_unit_names = build_info.compile_unit_names;
    const matched_compile_units: ?[]bool = if (compile_unit_names) |names| matched: {
        const matched = oom(self.runtime.sessionArena().alloc(bool, names.len));
        @memset(matched, false);
        break :matched matched;
    } else null;

    const build_config = self.build_config_store.buildConfig(config_id);
    for (0..build_config.steps.len) |step_index| {
        const step = build_config.steps[step_index];
        if (step.extended.cast(
            build_config,
            std.Build.Configuration.Step.Compile,
        ) == null) continue;

        if (compile_unit_names) |names| {
            const step_name = step.name.slice(build_config);
            const name_index = indexOfName(names, step_name) orelse continue;
            matched_compile_units.?[name_index] = true;
        }

        try self.consumeBuildConfigStep(
            config_id,
            @enumFromInt(step_index),
        );
    }

    if (compile_unit_names) |names| {
        for (matched_compile_units.?, 0..) |matched, index| {
            if (!matched) {
                std.log.err("Selected compile unit '{s}' was not found in the evaluated build configuration", .{
                    names[index],
                });
                return error.InvalidBuildConfig;
            }
        }
    }

    return config_id;
}

fn indexOfName(names: []const []const u8, needle: []const u8) ?usize {
    for (names, 0..) |name, index| {
        if (std.mem.eql(u8, name, needle)) return index;
    }
    return null;
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

    _ = self.appendCompileContext(.{
        .step_index = step_index,
        .root_module = root_module_id,
    });
}

pub fn appendCompileContext(
    self: *LintContext,
    context: CompileContext,
) CompileContext.Id {
    const id: CompileContext.Id = .fromIndex(self.compile_contexts.len);
    oom(self.compile_contexts.append(self.runtime.sessionArena(), context));
    self.module_file_index_built = false;
    return id;
}

pub fn compileContext(
    self: *const LintContext,
    id: CompileContext.Id,
) CompileContext {
    return self.compile_contexts.get(id.toIndex());
}

pub fn compileContextIdForModule(
    self: *const LintContext,
    module_id: ModuleStore.ModuleId,
) ?CompileContext.Id {
    for (self.compile_contexts.items(.root_module), 0..) |root_module, index| {
        if (root_module == module_id) return .fromIndex(index);
    }
    return null;
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
    defer module_id_by_build_module_index.deinit(self.runtime.sessionArena());

    var queue: std.ArrayList(std.Build.Configuration.Module.Index) = .empty;
    defer queue.deinit(self.runtime.sessionArena());

    const root_module_id = try self.resolveBuildModuleShallow(
        config_id,
        build_module_index,
    ) orelse return null;

    module_id_by_build_module_index.put(self.runtime.sessionArena(), build_module_index, root_module_id) catch unreachable;
    queue.append(self.runtime.sessionArena(), build_module_index) catch unreachable;

    while (queue.pop()) |current_build_module_index| {
        const current_module_id = module_id_by_build_module_index.get(current_build_module_index).?;

        // This exact build module may already have been populated by an earlier compile step.
        if (self.module_store.moduleIdsByImportName(current_module_id).count() != 0) {
            continue;
        }

        const build_module = current_build_module_index.get(build_config);

        const imports = build_module.import_table.get(build_config).imports.mal;
        var module_id_by_import_name: std.StringHashMapUnmanaged(ModuleStore.ModuleId) = .empty;

        oom(module_id_by_import_name.ensureTotalCapacity(
            self.runtime.sessionArena(),
            @intCast(imports.len),
        ));

        for (imports.items(.name), imports.items(.module)) |
            build_import_name_id,
            build_import_module_index,
        | {
            const import_name_slice = build_import_name_id.slice(build_config);

            const import_module_id = module_id_by_build_module_index
                .get(build_import_module_index) orelse child: {
                const resolved = (try self.resolveBuildModuleShallow(
                    config_id,
                    build_import_module_index,
                )) orelse continue;

                oom(module_id_by_build_module_index.put(
                    self.runtime.sessionArena(),
                    build_import_module_index,
                    resolved,
                ));

                oom(queue.append(
                    self.runtime.sessionArena(),
                    build_import_module_index,
                ));

                break :child resolved;
            };

            module_id_by_import_name.putAssumeCapacity(
                self.runtime.sessionArena().dupe(u8, import_name_slice) catch unreachable,
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

    var root_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = try files.resolveLazyPath(
        root_source_file,
        build_config,
        build_root_path,
        &root_path_buffer,
    ) orelse return null;

    return self.module_store.resolve(.{
        .root_file = try self.file_store.resolve(root_path),
        .build_config = config_id,
        .build_config_module = build_module_index,
        .module_id_by_import_name = .empty,
    });
}

pub fn resolveFile(self: *LintContext, input_path: []const u8) !FileStore.FileId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveFile");
    defer zone.end();

    const id = try self.file_store.resolve(input_path);
    self.decl_store.resolveFileTypes(
        id,
        .{
            .file_store = &self.file_store,
            .module_store = &self.module_store,
            .parent_file_id = id,
            .module_id = null,
            .root_file_id = null,
        },
        &self.type_store,
    );
    return id;
}

/// Resolves file-level type information and records declarations for module
/// contexts that can reach it.
///
/// This avoids choosing one active module when imports can resolve to
/// different declarations across compile units.
pub fn resolveFileTypes(
    self: *LintContext,
    file_id: FileStore.FileId,
) void {
    self.decl_store.resolveFileTypes(
        file_id,
        .{
            .file_store = &self.file_store,
            .module_store = &self.module_store,
            .parent_file_id = file_id,
            .module_id = null,
            .root_file_id = null,
        },
        &self.type_store,
    );

    const module_ids = self.moduleIdsForFile(file_id);
    for (module_ids) |module_id| {
        self.resolveFileTypesForModule(file_id, module_id);
    }
}

/// Ensures declarations are available for module-specific lazy resolution.
fn resolveFileTypesForModule(
    self: *LintContext,
    file_id: FileStore.FileId,
    module_id: ModuleStore.ModuleId,
) void {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveFileTypesForModule");
    defer zone.end();

    _ = module_id;
    _ = self.decl_store.store(file_id, &self.file_store);
}

/// Returns cached type information for a declaration in one module context,
/// computing it on demand so module-specific import resolution is preserved.
fn cacheResolvedDeclTypeForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ResolvedDeclType {
    const zone = tracy.traceNamed(@src(), "LintContext.cacheResolvedDeclTypeForModule");
    defer zone.end();

    const key: ResolvedDeclTypeKey = .{
        .module_id = module_id,
        .decl_id = decl_id,
    };
    if (self.resolved_decl_types_by_module.get(key)) |resolved| return resolved;

    const resolution = self.resolutionForModule(module_id);
    const type_id = if (resolution.declType(decl_id)) |summary|
        self.type_store.store(summary)
    else
        null;

    const type_target = resolution.declTypeTargetForValue(decl_id);

    const resolved: ResolvedDeclType = .{
        .type_id = type_id,
        .type_target = type_target,
    };
    oom(self.resolved_decl_types_by_module.put(
        self.runtime.sessionArena(),
        key,
        resolved,
    ));
    return resolved;
}

fn resolutionForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
) ModuleResolution {
    return .{
        .session = self,
        .module_id = module_id,
    };
}

pub fn moduleIdsForFile(
    self: *LintContext,
    file_id: FileStore.FileId,
) []const ModuleStore.ModuleId {
    const zone = tracy.traceNamed(@src(), "LintContext.moduleIdsForFile");
    defer zone.end();
    zone.setValue(file_id.toIndex());

    self.ensureModuleIdsByFile(self.runtime.sessionArena());

    const cached = self.module_ids_by_file.get(file_id) orelse fallback: {
        const module_id = self.module_store.resolve(.{
            .root_file = file_id,
            .build_config = .fromIndex(0),
            .build_config_module = @enumFromInt(file_id.toIndex()),
            .module_id_by_import_name = .empty,
        });
        self.indexModuleFiles(module_id, self.runtime.sessionArena());
        break :fallback self.module_ids_by_file.get(file_id) orelse
            unreachable;
    };

    return cached.items;
}

fn moduleIdsForDecl(self: *LintContext, decl_id: DeclStore.DeclId) []const ModuleStore.ModuleId {
    return self.moduleIdsForFile(self.decl_store.declFileId(decl_id));
}

fn ensureModuleIdsByFile(
    self: *LintContext,
    gpa: std.mem.Allocator,
) void {
    const zone = tracy.traceNamed(@src(), "LintContext.ensureModuleIdsByFile");
    defer zone.end();
    zone.setValue(@intFromBool(self.module_file_index_built));

    if (self.module_file_index_built) return;

    for (self.compile_contexts.items(.root_module)) |root_module_id| {
        self.indexModuleFiles(root_module_id, gpa);
    }

    self.module_file_index_built = true;
}

fn appendModuleForFile(
    self: *LintContext,
    file_id: FileStore.FileId,
    module_id: ModuleStore.ModuleId,
) void {
    const entry = oom(self.module_ids_by_file.getOrPut(
        self.runtime.sessionArena(),
        file_id,
    ));
    if (!entry.found_existing)
        entry.value_ptr.* = .empty;

    if (self.module_store.rootFileId(module_id) == file_id) {
        oom(entry.value_ptr.insert(self.runtime.sessionArena(), 0, module_id));
    } else {
        oom(entry.value_ptr.append(self.runtime.sessionArena(), module_id));
    }
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

fn indexModuleFiles(
    self: *LintContext,
    root_module_id: ModuleStore.ModuleId,
    gpa: std.mem.Allocator,
) void {
    const zone = tracy.traceNamed(@src(), "LintContext.indexModuleFiles");
    defer zone.end();
    zone.setValue(root_module_id.toIndex());

    const compile_root_file_id = self.module_store.rootFileId(root_module_id);

    var visited = std.AutoHashMapUnmanaged(ReachKey, void).empty;
    defer visited.deinit(gpa);

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

        self.appendModuleForFile(item.file_id, root_module_id);

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
                        .{
                            .file_store = &self.file_store,
                            .module_store = &self.module_store,
                            .parent_file_id = item.file_id,
                            .module_id = item.module_id,
                            .root_file_id = compile_root_file_id,
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
        .context_scope_by_node = oom(gpa.alloc(?DeclStore.ScopeId, tree.nodes.len)),
    };
    @memset(doc.context_scope_by_node, null);

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

pub const DeclCandidate = struct {
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
};

pub const TypeCandidate = struct {
    module_id: ModuleStore.ModuleId,
    type: ResolvedNodeType,
};

pub const EnumCandidate = struct {
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
};

pub const DeclValueSummaryCandidate = struct {
    module_id: ModuleStore.ModuleId,
    summary: TypeStore.TypeSummary,
};

pub const ValueTypeAnnotationCandidate = struct {
    summary: TypeStore.TypeSummary,
    source_decl_id: ?DeclStore.DeclId = null,
};

pub const DeclLocation = struct {
    abs_path: []const u8,
    start: results.LintProblemLocation,
    end: results.LintProblemLocation,
    line: usize,
    column: usize,
};

/// Follows simple value aliases from a declaration in one module context.
pub fn resolveDeclAliasForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) DeclStore.DeclId {
    return self.resolveDeclAliasCandidate(.{
        .module_id = module_id,
        .decl_id = decl_id,
    }).decl_id;
}

/// Resolves the type summary for an expression node in a single module.
fn resolveTypeOfNodeForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?ResolvedNodeType {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveTypeOfNode");
    defer zone.end();

    const immediate_decl_id = self.resolveDeclOfNodeForModule(module_id, doc, node);
    const resolved_decl_id = if (immediate_decl_id) |decl_id|
        self.decl_store.resolvedContainerDecl(
            &self.file_store,
            decl_id,
        ) orelse decl_id
    else
        null;

    if (resolved_decl_id) |decl_id| {
        if (self.cacheResolvedDeclTypeForModule(module_id, decl_id).type_id) |type_id| {
            return .{
                .summary = self.type_store.summary(type_id),
                .decl_id = decl_id,
            };
        }
    }

    return null;
}

/// Resolves `node` to the declaration it directly names in a single module.
pub fn resolveDeclOfNodeForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclOfNode");
    defer zone.end();

    const key = ResolvedNodeDeclKey.init(module_id, doc.file_id, node);
    if (self.resolved_decl_by_module_file_node.get(key)) |cached|
        return cached;

    const decl_id = self.immediateDeclForNode(module_id, doc, node);
    oom(self.resolved_decl_by_module_file_node.put(
        self.runtime.sessionArena(),
        key,
        decl_id,
    ));
    return decl_id;
}

/// Resolves `node` to all declarations it names across the modules reachable
/// from the file. This is the new semantic entrypoint for ambiguous lookup.
pub fn resolveDeclCandidatesOfNode(
    self: *LintContext,
    arena: std.mem.Allocator,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ![]const DeclCandidate {
    const key: FileNodeKey = .{
        .file_id = doc.file_id,
        .node = node,
    };
    if (self.decl_cands_by_node.get(key)) |cached| {
        return cached;
    }

    var candidates = std.ArrayList(DeclCandidate).empty;
    const module_ids = self.moduleIdsForFile(doc.file_id);
    for (module_ids) |module_id| {
        if (self.resolveDeclOfNodeForModule(module_id, doc, node)) |decl_id| {
            try candidates.append(arena, .{
                .module_id = module_id,
                .decl_id = decl_id,
            });
        }
    }

    const owned = try self.runtime.sessionArena().dupe(
        DeclCandidate,
        candidates.items,
    );
    oom(self.decl_cands_by_node.put(
        self.runtime.sessionArena(),
        key,
        owned,
    ));
    return owned;
}

/// Resolves a member declaration from a container/type declaration.
fn resolveDeclMemberForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    parent_decl_id: DeclStore.DeclId,
    member_name: []const u8,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclMember");
    defer zone.end();

    return self.resolutionForModule(module_id).memberDecl(parent_decl_id, member_name);
}

/// Resolves a member declaration from a container/type declaration across all
/// modules that can reach the declaration's file.
pub fn resolveDeclMemberCandidates(
    self: *LintContext,
    arena: std.mem.Allocator,
    parent_decl_id: DeclStore.DeclId,
    member_name: []const u8,
) ![]const DeclCandidate {
    var candidates = std.ArrayList(DeclCandidate).empty;
    const module_ids = self.moduleIdsForDecl(parent_decl_id);
    for (module_ids) |module_id| {
        const decl_id = self.resolveDeclMemberForModule(
            module_id,
            parent_decl_id,
            member_name,
        ) orelse continue;
        try candidates.append(arena, .{
            .module_id = module_id,
            .decl_id = decl_id,
        });
    }
    return candidates.items;
}

/// Resolves a member declaration from each declaration candidate, preserving
/// the candidate module used for lookup.
pub fn resolveDeclMemberCandidatesFromCandidates(
    self: *LintContext,
    arena: std.mem.Allocator,
    parent_candidates: []const DeclCandidate,
    member_name: []const u8,
) ![]const DeclCandidate {
    var candidates = std.ArrayList(DeclCandidate).empty;
    for (parent_candidates) |parent| {
        const decl_id = self.resolveDeclMemberForModule(
            parent.module_id,
            parent.decl_id,
            member_name,
        ) orelse continue;
        try candidates.append(arena, .{
            .module_id = parent.module_id,
            .decl_id = decl_id,
        });
    }
    return candidates.items;
}

/// Follows simple value aliases from a declaration candidate while preserving
/// its module context.
pub fn resolveDeclAliasCandidate(
    self: *LintContext,
    candidate: DeclCandidate,
) DeclCandidate {
    var current_decl_id = candidate.decl_id;
    var remaining_alias_depth: u8 = 16;

    const resolution = self.resolutionForModule(candidate.module_id);
    while (remaining_alias_depth > 0) : (remaining_alias_depth -= 1) {
        const file_id = self.decl_store.declFileId(current_decl_id);
        const tree = self.file_store.fileTree(file_id);
        const decl_node = self.decl_store.declAstNode(current_decl_id) orelse break;
        const var_decl = tree.fullVarDecl(decl_node) orelse break;
        const init_node = var_decl.ast.init_node.unwrap() orelse break;
        const target_decl_id = resolution.nodeDeclWithRoot(
            current_decl_id,
            init_node,
        ) orelse break;

        if (target_decl_id == current_decl_id) break;
        current_decl_id = target_decl_id;
    }

    return .{
        .module_id = candidate.module_id,
        .decl_id = current_decl_id,
    };
}

/// Resolves the type of `node` for every module reachable from the file.
pub fn resolveTypeCandidatesOfNode(
    self: *LintContext,
    arena: std.mem.Allocator,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ![]const TypeCandidate {
    var candidates = std.ArrayList(TypeCandidate).empty;
    const module_ids = self.moduleIdsForFile(doc.file_id);
    for (module_ids) |module_id| {
        if (self.resolveTypeOfNodeForModule(module_id, doc, node)) |resolved| {
            try candidates.append(arena, .{
                .module_id = module_id,
                .type = resolved,
            });
        }
    }
    return candidates.items;
}

/// Resolves `node` to all enum declarations it can name across reachable modules.
pub fn resolveEnumCandidatesOfNode(
    self: *LintContext,
    arena: std.mem.Allocator,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ![]const EnumCandidate {
    var candidates = std.ArrayList(EnumCandidate).empty;
    const module_ids = self.moduleIdsForFile(doc.file_id);
    for (module_ids) |module_id| {
        if (self.resolveEnumDeclOfNodeForModule(module_id, doc, node)) |decl_id| {
            try candidates.append(arena, .{
                .module_id = module_id,
                .decl_id = decl_id,
            });
        }
    }
    return candidates.items;
}

/// Resolves an expression to all enum tag names it can name across reachable
/// modules.
pub fn resolveEnumTagNameCandidatesOfNode(
    self: *LintContext,
    arena: std.mem.Allocator,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ![]const []const u8 {
    var candidates = std.ArrayList([]const u8).empty;
    const module_ids = self.moduleIdsForFile(doc.file_id);
    for (module_ids) |module_id| {
        if (self.resolveEnumTagNameOfNodeForModule(
            module_id,
            doc,
            node,
        )) |tag_name| {
            try candidates.append(arena, tag_name);
        }
    }
    return candidates.items;
}

/// Resolves a member from the type represented by a declaration.
fn resolveDeclTypeMemberForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    parent_decl_id: DeclStore.DeclId,
    member_name: []const u8,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclTypeMember");
    defer zone.end();

    return self.resolutionForModule(module_id).declTypeMember(parent_decl_id, member_name);
}

/// Resolves a member from the type represented by a declaration across all
/// modules that can reach the declaration's file.
pub fn resolveDeclTypeMemberCandidates(
    self: *LintContext,
    arena: std.mem.Allocator,
    parent_decl_id: DeclStore.DeclId,
    member_name: []const u8,
) ![]const DeclCandidate {
    var candidates = std.ArrayList(DeclCandidate).empty;
    const module_ids = self.moduleIdsForDecl(parent_decl_id);
    for (module_ids) |module_id| {
        const decl_id = self.resolveDeclTypeMemberForModule(
            module_id,
            parent_decl_id,
            member_name,
        ) orelse continue;

        try candidates.append(arena, .{
            .module_id = module_id,
            .decl_id = decl_id,
        });
    }
    return candidates.items;
}

/// Resolves the declaration named by a declaration's type expression.
fn resolveDeclTypeDeclForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclTypeDecl");
    defer zone.end();

    return self.resolutionForModule(module_id).declTypeDecl(decl_id);
}

/// Resolves the declaration named by a declaration's type expression across
/// all modules that can reach the declaration's file.
pub fn resolveDeclTypeDeclCandidates(
    self: *LintContext,
    arena: std.mem.Allocator,
    decl_id: DeclStore.DeclId,
) ![]const DeclCandidate {
    var candidates = std.ArrayList(DeclCandidate).empty;
    const module_ids = self.moduleIdsForDecl(decl_id);
    for (module_ids) |module_id| {
        const type_decl_id = self.resolveDeclTypeDeclForModule(
            module_id,
            decl_id,
        ) orelse continue;

        try candidates.append(arena, .{
            .module_id = module_id,
            .decl_id = type_decl_id,
        });
    }
    return candidates.items;
}

/// Resolves the declaration named by each candidate's type expression,
/// preserving the candidate module used for lookup.
pub fn resolveDeclTypeDeclCandidatesFromCandidates(
    self: *LintContext,
    arena: std.mem.Allocator,
    decl_candidates: []const DeclCandidate,
) ![]const DeclCandidate {
    var candidates = std.ArrayList(DeclCandidate).empty;
    for (decl_candidates) |candidate| {
        const type_decl_id = self.resolveDeclTypeDeclForModule(
            candidate.module_id,
            candidate.decl_id,
        ) orelse continue;
        try candidates.append(arena, .{
            .module_id = candidate.module_id,
            .decl_id = type_decl_id,
        });
    }
    return candidates.items;
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
        session: *const LintContext,
        buffer: *[2]Ast.Node.Index,
    ) ?Ast.full.ContainerDecl {
        const tree = session.file_store.fileTree(self.file_id);
        return tree.fullContainerDecl(buffer, self.container_node);
    }

    pub fn tagName(self: EnumInfo, session: *const LintContext, member: Ast.Node.Index) ?[]const u8 {
        return enumMemberTagName(session.file_store.fileTree(self.file_id), member);
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
fn resolveEnumDeclOfNodeForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    doc: *const LintDocument,
    expr_node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const tree = doc.tree(self);
    const node = ast.unwrapNode(tree, expr_node, .{
        .unwrap_optional_unwrap = false,
    });

    var call_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullCall(&call_buffer, node)) |call| {
        const callee_decl_id = self.resolveDeclOfNodeForModule(
            module_id,
            doc,
            call.ast.fn_expr,
        ) orelse return null;
        return self.resolveFunctionReturnEnumDecl(module_id, callee_decl_id);
    }

    const decl_id = self.resolveDeclOfNodeForModule(module_id, doc, node) orelse return null;
    return self.resolveDeclEnumType(module_id, decl_id);
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
fn resolveEnumTagNameOfNodeForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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
            const decl_id = self.resolveDeclOfNodeForModule(
                module_id,
                doc,
                node,
            ) orelse break :tag_name null;
            break :tag_name self.tagNameFromDeclValue(module_id, decl_id);
        },
        else => null,
    };
}

fn resolveFunctionReturnEnumDecl(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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
    const return_decl_id = self.resolutionForModule(module_id).declByNode(
        fn_decl_id,
        return_type,
    ) orelse return null;

    return self.resolveEnumDeclAlias(module_id, return_decl_id);
}

fn resolveDeclEnumType(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    if (self.enumInfo(decl_id) != null) return decl_id;

    if (self.resolveDeclTypeDeclForModule(module_id, decl_id)) |type_decl_id| {
        if (self.resolveEnumDeclAlias(module_id, type_decl_id)) |enum_decl_id|
            return enum_decl_id;
    }

    return self.resolveEnumDeclFromValue(module_id, decl_id);
}

fn resolveEnumDeclFromValue(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ?DeclStore.DeclId {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const decl_node = self.decl_store.declAstNode(decl_id) orelse return null;
    const var_decl = tree.fullVarDecl(decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;

    return self.resolveEnumDeclFromValueExpr(
        module_id,
        decl_id,
        init_node,
    );
}

fn resolveEnumDeclFromValueExpr(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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
        const lhs_decl_id = self.resolutionForModule(module_id).declByNode(
            context_decl_id,
            lhs,
        ) orelse return null;
        return self.resolveEnumDeclAlias(module_id, lhs_decl_id);
    }

    const target_decl_id = self.resolutionForModule(module_id).declByNode(
        context_decl_id,
        node,
    ) orelse return null;
    return self.resolveDeclEnumType(module_id, target_decl_id);
}

fn resolveEnumDeclAlias(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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
        const target_decl_id = self.resolutionForModule(module_id).declByNode(
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
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ?[]const u8 {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);
    const decl_node = self.decl_store.declAstNode(decl_id) orelse return null;
    const var_decl = tree.fullVarDecl(decl_node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;

    return self.tagNameFromValueExpr(module_id, decl_id, init_node);
}

fn tagNameFromValueExpr(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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
            const target_decl_id = self.resolutionForModule(module_id).declByNode(
                context_decl_id,
                node,
            ) orelse break :blk null;
            break :blk self.tagNameFromDeclValue(module_id, target_decl_id);
        },
        else => null,
    };
}

/// Allocates the leading doc comments for a declaration without comment tokens.
pub fn allocDeclDocComments(
    self: *const LintContext,
    arena: std.mem.Allocator,
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
        if (token != first_doc_token) oom(comments_text.append(arena, '\n'));

        const raw = tree.tokenSlice(token);
        const without_marker = if (std.mem.startsWith(u8, raw, "///") or
            std.mem.startsWith(u8, raw, "//!"))
            raw[3..]
        else
            raw;
        oom(comments_text.appendSlice(arena, without_marker));
    }

    return oom(comments_text.toOwnedSlice(arena));
}

/// Returns the source span to show when explaining where a declaration lives.
///
/// Prefer the declaration name when available because secondary diagnostics are
/// easier to scan when they point at the identifier instead of the full decl.
pub fn declLocation(
    self: *const LintContext,
    decl_id: DeclStore.DeclId,
) ?DeclLocation {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);

    const first_token, const start, const end = if (self.decl_store.declNameToken(decl_id)) |name_token|
        .{
            name_token,
            results.LintProblemLocation.startOfToken(tree, name_token),
            results.LintProblemLocation.endOfToken(tree, name_token),
        }
    else if (self.decl_store.declAstNode(decl_id)) |node|
        .{
            tree.firstToken(node),
            results.LintProblemLocation.startOfNode(tree, node),
            results.LintProblemLocation.endOfNode(tree, node),
        }
    else
        return null;
    const token_location = tree.tokenLocation(0, first_token);

    return .{
        .abs_path = self.file_store.fileAbsPath(file_id),
        .start = start,
        .end = end,
        .line = token_location.line,
        .column = token_location.column,
    };
}

/// Resolves `node` to the declaration it directly names.
///
/// Expression lookup needs a lexical starting point, so this first finds the
/// nearest declaration containing `node` and then resolves from that scope.
fn immediateDeclForNode(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    doc: *const LintDocument,
    node: Ast.Node.Index,
) ?DeclStore.DeclId {
    const zone = tracy.traceNamed(@src(), "LintContext.immediateDeclForNode");
    defer zone.end();

    if (self.decl_store.declIdByNode(doc.file_id, node)) |decl_id| {
        return decl_id;
    }

    const context_scope_id = self.contextScopeForNode(doc, node) orelse return null;

    return self.resolutionForModule(module_id).declByNodeFromScope(
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

    const node_index = @intFromEnum(node);
    if (node_index < doc.context_scope_by_node.len) {
        if (doc.context_scope_by_node[node_index]) |scope_id| {
            return scope_id;
        }
    }

    var current: ?Ast.Node.Index = node;
    while (current) |current_node| {
        if (self.decl_store.scopeIdByNode(doc.file_id, current_node)) |scope_id| {
            if (node_index < doc.context_scope_by_node.len) {
                @constCast(doc).context_scope_by_node[node_index] = scope_id;
            }
            return scope_id;
        }

        current = doc.lineage.items(.parent)[@intFromEnum(current_node)];
    }
    const root_scope_id = self.decl_store.scopeIdByNode(doc.file_id, .root);
    if (root_scope_id) |scope_id| {
        if (node_index < doc.context_scope_by_node.len) {
            @constCast(doc).context_scope_by_node[node_index] = scope_id;
        }
    }
    return root_scope_id;
}

/// Resolves the coarse value kind for a declaration in one module context.
fn resolveDeclValueKindForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ?TypeStore.Type {
    return if (self.resolveDeclValueSummaryForModule(module_id, decl_id)) |summary|
        summary.coarseType()
    else
        null;
}

/// Resolves the value summary for a declaration in one module context.
fn resolveDeclValueSummaryForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
) ?TypeStore.TypeSummary {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclValueSummaryForModule");
    defer zone.end();

    const key: ResolvedDeclSummaryKey = .{
        .module_id = module_id,
        .decl_id = decl_id,
    };
    if (self.decl_value_summary_by_module.get(key)) |summary| {
        zone.setValue(1);
        return summary;
    }

    zone.setValue(0);
    const summary = self.resolveDeclValueSummaryDepth(module_id, decl_id, 16);
    oom(self.decl_value_summary_by_module.put(
        self.runtime.sessionArena(),
        key,
        summary,
    ));
    return summary;
}

/// Resolves value summaries for a declaration across every module that can
/// reach its file.
pub fn resolveDeclValueSummaryCandidates(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) ![]const DeclValueSummaryCandidate {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclValueSummaryCandidates");
    defer zone.end();

    if (self.decl_summary_cands_by_decl.get(decl_id)) |cached| {
        zone.setValue(cached.len);
        return cached;
    }

    var candidates = std.ArrayList(DeclValueSummaryCandidate).empty;
    const module_ids = self.moduleIdsForDecl(decl_id);
    for (module_ids) |module_id| {
        const summary = self.resolveDeclValueSummaryForModule(
            module_id,
            decl_id,
        ) orelse continue;
        try candidates.append(self.runtime.sessionArena(), .{
            .module_id = module_id,
            .summary = summary,
        });
    }
    const owned = try self.runtime.sessionArena().dupe(
        DeclValueSummaryCandidate,
        candidates.items,
    );
    oom(self.decl_summary_cands_by_decl.put(
        self.runtime.sessionArena(),
        decl_id,
        owned,
    ));
    zone.setValue(owned.len);
    return owned;
}

/// Resolves value summaries for existing declaration candidates while keeping
/// each candidate's module context.
pub fn resolveDeclValueSummaryCandidatesFromCandidates(
    self: *LintContext,
    arena: std.mem.Allocator,
    decl_candidates: []const DeclCandidate,
) ![]const DeclValueSummaryCandidate {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclValueSummaryCandidatesFromCandidates");
    defer zone.end();
    zone.setValue(decl_candidates.len);

    var candidates = std.ArrayList(DeclValueSummaryCandidate).empty;
    for (decl_candidates) |candidate| {
        const summary = self.resolveDeclValueSummaryForModule(
            candidate.module_id,
            candidate.decl_id,
        ) orelse continue;
        try candidates.append(arena, .{
            .module_id = candidate.module_id,
            .summary = summary,
        });
    }
    return candidates.items;
}

/// Classifies a type annotation by the kinds of values it admits. This keeps
/// module-specific declaration resolution and source locations so callers can
/// explain cross-module ambiguity consistently.
pub fn resolveValueTypeAnnotationCandidates(
    self: *LintContext,
    doc: *const LintDocument,
    type_node: Ast.Node.Index,
) ![]const ValueTypeAnnotationCandidate {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveValueTypeAnnotationCandidates");
    defer zone.end();

    const key: FileNodeKey = .{
        .file_id = doc.file_id,
        .node = type_node,
    };
    if (self.type_annotation_cands_by_node.get(key)) |cached| {
        zone.setValue(cached.len);
        return cached;
    }

    var candidates = std.ArrayList(ValueTypeAnnotationCandidate).empty;
    errdefer candidates.deinit(self.runtime.sessionArena());

    const tree = doc.tree(self);
    if (directValueTypeAnnotationSummary(
        tree,
        type_node,
    )) |summary| {
        try candidates.append(
            self.runtime.sessionArena(),
            .{ .summary = summary },
        );
        const owned = try self.runtime.sessionArena().dupe(
            ValueTypeAnnotationCandidate,
            candidates.items,
        );
        oom(self.type_annotation_cands_by_node.put(
            self.runtime.sessionArena(),
            key,
            owned,
        ));
        zone.setValue(owned.len);
        return owned;
    }

    const decl_candidates = try self.resolveDeclCandidatesOfNode(
        self.runtime.sessionArena(),
        doc,
        typeReferenceNode(tree, type_node),
    );

    if (decl_candidates.len == 0) {
        try candidates.append(self.runtime.sessionArena(), .{
            .summary = .other,
        });
        const owned = try self.runtime.sessionArena().dupe(
            ValueTypeAnnotationCandidate,
            candidates.items,
        );
        oom(self.type_annotation_cands_by_node.put(
            self.runtime.sessionArena(),
            key,
            owned,
        ));
        zone.setValue(owned.len);
        return owned;
    }

    for (decl_candidates) |decl_candidate| {
        const source_decl_id = self.resolveDeclAliasCandidate(
            decl_candidate,
        ).decl_id;

        const resolved_summary = self.resolveDeclValueSummaryForModule(
            decl_candidate.module_id,
            source_decl_id,
        ) orelse continue;

        try candidates.append(self.runtime.sessionArena(), .{
            .summary = resolvedValueTypeAnnotationSummary(
                self,
                source_decl_id,
                resolved_summary,
            ),
            .source_decl_id = source_decl_id,
        });
    }

    if (candidates.items.len == 0)
        try candidates.append(
            self.runtime.sessionArena(),
            .{ .summary = .other },
        );

    const owned = try self.runtime.sessionArena().dupe(
        ValueTypeAnnotationCandidate,
        candidates.items,
    );
    oom(self.type_annotation_cands_by_node.put(
        self.runtime.sessionArena(),
        key,
        owned,
    ));
    zone.setValue(owned.len);
    return owned;
}

/// Recursively summarizes a declaration's value in one module context.
fn resolveDeclValueSummaryDepth(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    const zone = tracy.traceNamed(@src(), "LintContext.resolveDeclValueSummaryDepth");
    defer zone.end();
    zone.setValue(remaining_depth);

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
            return self.resolveValueTypeAnnotationSummaryForModule(
                module_id,
                decl_id,
                type_node,
                remaining_depth - 1,
            );
        }

        if (init_node) |value_node| {
            return self.typeSummaryFromValueNode(
                module_id,
                decl_id,
                value_node,
                remaining_depth - 1,
            );
        }
    }

    if (tree.fullContainerField(node)) |container_field| {
        const value_node = container_field.ast.value_expr.unwrap();
        if (container_field.ast.type_expr.unwrap()) |type_node| {
            return self.resolveValueTypeAnnotationSummaryForModule(
                module_id,
                decl_id,
                type_node,
                remaining_depth - 1,
            );
        }

        if (value_node) |expr| {
            return self.typeSummaryFromValueNode(
                module_id,
                decl_id,
                expr,
                remaining_depth - 1,
            );
        }
    }

    return null;
}

/// Recursively summarizes the Zig type of a declaration in one module context.
fn resolveDeclTypeSummaryDepth(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    decl_id: DeclStore.DeclId,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    if (remaining_depth == 0) return null;

    const file_id = self.decl_store.declFileId(decl_id);

    const resolved_type = self.cacheResolvedDeclTypeForModule(module_id, decl_id);
    if (resolved_type.type_id) |type_id| {
        const summary = self.type_store.summary(type_id);
        switch (summary) {
            .unknown, .other, .primitive => {},
            else => return summary,
        }
    }

    if (resolved_type.type_target) |target| {
        if (self.typeSummaryFromTarget(
            module_id,
            target,
            remaining_depth - 1,
        )) |summary| return summary;
    }

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
                module_id,
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
                module_id,
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
    module_id: ModuleStore.ModuleId,
    target: DeclStore.TypeTarget,
    remaining_depth: u8,
) ?TypeStore.TypeSummary {
    return switch (target) {
        .decl => |decl_id| self.resolveDeclTypeSummaryDepth(
            module_id,
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

fn resolveValueTypeAnnotationSummaryForModule(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
    context_decl_id: DeclStore.DeclId,
    type_node: Ast.Node.Index,
    remaining_depth: u8,
) TypeStore.TypeSummary {
    const tree = self.file_store.fileTree(
        self.decl_store.declFileId(context_decl_id),
    );

    if (directValueTypeAnnotationSummary(
        tree,
        type_node,
    )) |summary|
        return summary;

    if (remaining_depth == 0) return .other;

    const target_decl_id = self
        .resolutionForModule(module_id)
        .nodeDeclWithRoot(
        context_decl_id,
        typeReferenceNode(tree, type_node),
    ) orelse return .other;

    const source_decl_id = self.resolveDeclAliasCandidate(.{
        .module_id = module_id,
        .decl_id = target_decl_id,
    }).decl_id;

    const resolved_summary = self.resolveDeclValueSummaryDepth(
        module_id,
        source_decl_id,
        remaining_depth - 1,
    ) orelse return .other;

    return resolvedValueTypeAnnotationSummary(
        self,
        source_decl_id,
        resolved_summary,
    );
}

fn typeReferenceNode(
    tree: Ast,
    type_node: Ast.Node.Index,
) Ast.Node.Index {
    return ast.unwrapNode(tree, type_node, .{});
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

fn directValueTypeAnnotationSummary(
    tree: Ast,
    type_node: Ast.Node.Index,
) ?TypeStore.TypeSummary {
    const node = typeReferenceNode(tree, type_node);
    const summary = TypeStore.summarizeTypeNode(
        tree,
        node,
    );

    return switch (summary) {
        .@"fn", .fn_returns_type => summary,
        .type => |type_value| if (type_value.kind == .unknown and
            tree.nodeTag(node) == .identifier and
            std.mem.eql(u8, tree.getNodeSource(node), "type"))
            summary
        else
            .other,
        .unknown => switch (tree.nodeTag(node)) {
            .identifier, .field_access => null,
            else => .other,
        },
        .other, .primitive, .instance, .slice, .array => .other,
    };
}

fn resolvedValueTypeAnnotationSummary(
    self: *LintContext,
    source_decl_id: DeclStore.DeclId,
    summary: TypeStore.TypeSummary,
) TypeStore.TypeSummary {
    return switch (summary) {
        .unknown, .other, .primitive => .other,
        .@"fn", .fn_returns_type => summary,
        .type => |type_value| switch (type_value.kind) {
            .unknown => if (declIsExplicitTypeLiteral(self, source_decl_id)) summary else .other,
            .@"fn", .fn_returns_type => summary,
            else => .other,
        },
        .instance, .slice, .array => .other,
    };
}

fn declIsExplicitTypeLiteral(
    self: *LintContext,
    decl_id: DeclStore.DeclId,
) bool {
    const file_id = self.decl_store.declFileId(decl_id);
    const tree = self.file_store.fileTree(file_id);

    const decl_node = self.decl_store.declAstNode(decl_id) orelse
        return false;
    const var_decl = tree.fullVarDecl(decl_node) orelse
        return false;
    const init_node = var_decl.ast.init_node.unwrap() orelse
        return false;

    const init_expr = ast.unwrapNode(tree, init_node, .{});
    return tree.nodeTag(init_expr) == .identifier and
        std.mem.eql(u8, tree.getNodeSource(init_expr), "type");
}

fn typeSummaryFromValueNode(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
        return containerDeclTypeSummary(tree, container_decl);
    }

    if (ast.isBuiltinCallNamed(tree, node, "@import")) {
        const target_decl_id = self.resolveImportRootDecl(
            module_id,
            self.decl_store.declFileId(context_decl_id),
            node,
        ) orelse return null;

        return self.resolveDeclValueSummaryDepth(
            module_id,
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
        const callee_decl_id = self.resolutionForModule(module_id).nodeDeclWithRoot(
            context_decl_id,
            call.ast.fn_expr,
        ) orelse return null;
        const callee_summary = self.resolveDeclTypeSummaryDepth(
            module_id,
            callee_decl_id,
            remaining_depth - 1,
        ) orelse return null;
        if (callee_summary.coarseType() == .fn_returns_type) {
            if (self.resolutionForModule(module_id).typeFactoryResultTarget(
                callee_decl_id,
            )) |target| {
                return self.typeSummaryFromTarget(module_id, target, remaining_depth - 1);
            }
            return .{ .type = .unknown };
        }
    }

    if (tree.nodeTag(node) == .address_of) {
        const target_node = tree.nodeData(node).node;
        const target_decl_id = self.resolutionForModule(module_id).nodeDeclWithRoot(
            context_decl_id,
            target_node,
        ) orelse return null;

        return self.resolveDeclValueSummaryDepth(
            module_id,
            target_decl_id,
            remaining_depth - 1,
        );
    }

    const target_decl_id = self.resolutionForModule(module_id).nodeDeclWithRoot(
        context_decl_id,
        node,
    ) orelse return null;

    return self.resolveDeclValueSummaryDepth(
        module_id,
        target_decl_id,
        remaining_depth - 1,
    );
}

/// Resolves an `@import` root declaration in the active module context.
fn resolveImportRootDecl(
    self: *LintContext,
    module_id: ModuleStore.ModuleId,
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
        .{
            .file_store = &self.file_store,
            .module_store = &self.module_store,
            .parent_file_id = parent_file_id,
            .module_id = module_id,
            .root_file_id = self.module_store.rootFileId(module_id),
        },
        import_path,
    ) catch return null;

    const file_id = maybe_file_id orelse return null;
    self.resolveFileTypesForModule(file_id, module_id);
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
    return switch (tree.nodeTag(node)) {
        .unwrap_optional => valueExprIsTypeInfoProjection(tree, tree.nodeData(node).node_and_token[0]),
        .field_access => valueExprIsTypeInfoProjection(tree, tree.nodeData(node).node_and_token[0]),
        else => ast.isBuiltinCallNamed(tree, node, "@typeInfo"),
    };
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

test "LintSession.resolveTypeKind" {
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

        var session = testing.initFakeContext(arena.allocator(), std.testing.io);
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        const doc = try testing.loadFakeDocument(
            &session,
            tmp.dir,
            "test.zig",
            test_case.contents,
            arena.allocator(),
        );
        std.testing.expectEqual(doc.tree(&session).errors.len, 0) catch |err| {
            std.debug.print("Failed to parse AST:\n{s}\n", .{test_case.contents});
            for (doc.tree(&session).errors) |ast_err| {
                var buffer: [1024]u8 = undefined;

                var writer = std.Io.File.stderr().writer(std.testing.io, &buffer).interface;
                try doc.tree(&session).renderError(ast_err, &writer);
                try writer.flush();
            }
            return err;
        };

        const tree = doc.tree(&session);
        const node = tree.rootDecls()[0];

        const module_id = session.module_store.resolve(.{
            .root_file = doc.file_id,
            .build_config = .fromIndex(0),
            .build_config_module = @enumFromInt(0),
            .module_id_by_import_name = .empty,
        });

        const maybe_resolved_type = session.resolveTypeOfNodeForModule(module_id, doc, node);

        if (maybe_resolved_type == null or !TypeStore.TypeSummary.eql(
            maybe_resolved_type.?.summary,
            test_case.summary,
        )) {
            const border: [50]u8 = @splat('-');
            std.debug.print("\n{s}\n{s}\n{s}\n{s}\n", .{
                border,
                border,
                doc.tree(&session).getNodeSource(node),
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
test "moduleIdsForFile includes shared dependency children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.writeFile(tmp.dir, "root1.zig", "const dep = @import(\"dep\");");
    try testing.writeFile(tmp.dir, "root2.zig", "const dep = @import(\"dep\");");
    try tmp.dir.createDirPath(std.testing.io, "dep");
    try testing.writeFile(tmp.dir, "dep/root.zig", "pub const child = @import(\"child.zig\");");
    try testing.writeFile(tmp.dir, "dep/child.zig", "const root = @import(\"root\");");

    var session = testing.initFakeContext(
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

    const root1_file_id = try session.file_store.resolve(root1_path);
    const root2_file_id = try session.file_store.resolve(root2_path);
    const dep_root_file_id = try session.file_store.resolve(dep_root_path);
    const dep_child_file_id = try session.file_store.resolve(dep_child_path);

    const build_config_id: BuildConfigStore.ConfigId = .fromIndex(0);
    const root1_build_module: std.Build.Configuration.Module.Index = @enumFromInt(0);
    const root2_build_module: std.Build.Configuration.Module.Index = @enumFromInt(1);
    const dep_build_module: std.Build.Configuration.Module.Index = @enumFromInt(2);

    const dep_module_id = session.module_store.resolve(.{
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
    const root1_module_id = session.module_store.resolve(.{
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
    const root2_module_id = session.module_store.resolve(.{
        .root_file = root2_file_id,
        .build_config = build_config_id,
        .build_config_module = root2_build_module,
        .module_id_by_import_name = root2_imports,
    });

    _ = session.appendCompileContext(.{
        .step_index = @enumFromInt(0),
        .root_module = root1_module_id,
    });
    _ = session.appendCompileContext(.{
        .step_index = @enumFromInt(1),
        .root_module = root2_module_id,
    });

    const module_ids = session.moduleIdsForFile(dep_child_file_id);
    const cached_module_ids = session.module_ids_by_file.get(dep_child_file_id).?.items;
    try std.testing.expectEqual(@as(usize, 2), module_ids.len);
    try std.testing.expectEqual(cached_module_ids.ptr, module_ids.ptr);

    var found_root1 = false;
    var found_root2 = false;
    for (module_ids) |module_id| {
        const root_file_id = session.module_store.rootFileId(module_id);
        found_root1 = found_root1 or root_file_id == root1_file_id;
        found_root2 = found_root2 or root_file_id == root2_file_id;

        const resolved_root = try import_utils.resolveFile(
            .{
                .file_store = &session.file_store,
                .module_store = &session.module_store,
                .parent_file_id = dep_child_file_id,
                .module_id = module_id,
                .root_file_id = root_file_id,
            },
            "root",
        );
        try std.testing.expectEqual(root_file_id, resolved_root.?);
    }
    try std.testing.expect(found_root1);
    try std.testing.expect(found_root2);
}

const ast = @import("../ast.zig");
const builtin = @import("builtin");
const comments = @import("../comments.zig");
const files = @import("../files.zig");
const import_utils = @import("imports.zig");
const results = @import("../results.zig");
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
const TypeStore = @import("TypeStore.zig");
const Ast = std.zig.Ast;
const oom = @import("../allocations.zig").oom;
const LintRuntime = @import("LintRuntime.zig");

test {
    std.testing.refAllDecls(@This());
}
