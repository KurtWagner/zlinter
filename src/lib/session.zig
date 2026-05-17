//! Linting session context and document loading.

pub const max_zig_file_size_bytes = bytes: {
    const bytes_in_mb = 1024 * 1024;
    break :bytes 32 * bytes_in_mb;
};

pub const Handle = struct {
    abs_path: []const u8,
    source_owned: [:0]u8,
    tree: Ast,
    decl_index: semantic.DeclIndex,
};

/// A loaded and parsed zig file that is given to lint rules.
pub const LintDocument = struct {
    path: []const u8,
    handle: *Handle,
    lineage: ast.NodeLineage,
    comments: comments.CommentsDocument,
    skipper: comments.LazyRuleSkipper,

    pub fn deinit(self: *LintDocument, gpa: std.mem.Allocator) void {
        while (self.lineage.pop()) |connections| {
            connections.deinit(gpa);
        }

        self.lineage.deinit(gpa);
        gpa.free(self.path);
        self.comments.deinit(gpa);
        self.skipper.deinit();
    }

    /// Returns true if the problem should be skipped based on line level disable comments.
    pub fn shouldSkipProblem(self: *LintDocument, problem: LintProblem) error{OutOfMemory}!bool {
        return self.skipper.shouldSkip(problem);
    }

    /// Walks up from a node to its ancestors.
    pub fn nodeAncestorIterator(
        self: *const LintDocument,
        node: Ast.Node.Index,
    ) ast.NodeAncestorIterator {
        return .{
            .current = node,
            .lineage = &self.lineage,
        };
    }

    /// Walks down from a node through descendants (including the starting node).
    pub fn nodeLineageIterator(
        self: *const LintDocument,
        node: Ast.Node.Index,
        gpa: std.mem.Allocator,
    ) error{OutOfMemory}!ast.NodeLineageIterator {
        var it = ast.NodeLineageIterator{
            .gpa = gpa,
            .queue = .empty,
            .lineage = &self.lineage,
        };
        try it.queue.append(gpa, node);
        return it;
    }

    /// Returns true if the node appears within a test block.
    pub fn isEnclosedInTestBlock(self: *const LintDocument, node: Ast.Node.Index) bool {
        var next = node;
        while (self.lineage.items(.parent)[@intFromEnum(next)]) |parent| {
            switch (self.handle.tree.nodeTag(parent)) {
                .test_decl => return true,
                .@"if", .if_simple => if (isTestOnlyCondition(
                    self.handle.tree,
                    self.handle.tree.fullIf(parent).?,
                )) {
                    return true;
                },
                else => {},
            }
            next = parent;
        }
        return false;
    }
};

/// Returns true if the if statement appears to enforce that its block is test-only.
fn isTestOnlyCondition(tree: Ast, if_statement: Ast.full.If) bool {
    const cond_node = if_statement.ast.cond_expr;
    return switch (tree.nodeTag(cond_node)) {
        .identifier => std.mem.eql(u8, "is_test", tree.getNodeSource(cond_node)),
        .field_access => ast.isFieldVarAccess(tree, cond_node, &.{"is_test"}),
        else => false,
    };
}

/// The context of document and rule execution.
pub const LintContext = struct {
    const ImportCacheKey = struct {
        importer_abs_path: []const u8,
        import_path: []const u8,
    };

    const ImportCacheContext = struct {
        pub fn hash(_: @This(), key: ImportCacheKey) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.importer_abs_path);
            hasher.update(&[_]u8{0});
            hasher.update(key.import_path);
            return hasher.final();
        }

        pub fn eql(_: @This(), lhs: ImportCacheKey, rhs: ImportCacheKey) bool {
            return std.mem.eql(u8, lhs.importer_abs_path, rhs.importer_abs_path) and
                std.mem.eql(u8, lhs.import_path, rhs.import_path);
        }
    };

    environ_map: *const std.process.Environ.Map,
    gpa: std.mem.Allocator,
    io: std.Io,
    loaded_handles: std.ArrayList(*Handle),
    import_handle_cache: std.HashMapUnmanaged(
        ImportCacheKey,
        ?*Handle,
        ImportCacheContext,
        std.hash_map.default_max_load_percentage,
    ),
    semantic_ctx: semantic.SemanticContext,

    pub const TypeKind = enum {
        other,
        @"fn",
        fn_returns_type,
        opaque_instance,
        enum_instance,
        struct_instance,
        union_instance,
        error_type,
        fn_type,
        fn_type_returns_type,
        type,
        enum_type,
        struct_type,
        namespace_type,
        union_type,
        opaque_type,

        pub fn name(self: TypeKind) []const u8 {
            return switch (self) {
                .other => "Other",
                .@"fn" => "Function",
                .fn_returns_type => "Type function",
                .opaque_instance => "Opaque instance",
                .enum_instance => "Enum instance",
                .struct_instance => "Struct instance",
                .union_instance => "Union instance",
                .error_type => "Error",
                .fn_type => "Function type",
                .fn_type_returns_type => "Type function type",
                .type => "Type",
                .enum_type => "Enum",
                .struct_type => "Struct",
                .namespace_type => "Namespace",
                .union_type => "Union",
                .opaque_type => "Opaque",
            };
        }
    };

    pub fn init(
        self: *LintContext,
        io: std.Io,
        environ_map: *const std.process.Environ.Map,
        gpa: std.mem.Allocator,
    ) !void {
        self.* = .{
            .gpa = gpa,
            .io = io,
            .environ_map = environ_map,
            .loaded_handles = .empty,
            .import_handle_cache = .empty,
            .semantic_ctx = .init(null),
        };
    }

    pub fn setBuildInfo(self: *LintContext, build_info: *const BuildInfo) void {
        self.semantic_ctx.setBuildInfo(build_info);
    }

    pub fn deinit(self: *LintContext) void {
        var import_cache_it = self.import_handle_cache.keyIterator();
        while (import_cache_it.next()) |key| {
            self.gpa.free(key.importer_abs_path);
            self.gpa.free(key.import_path);
        }
        self.import_handle_cache.deinit(self.gpa);

        for (self.loaded_handles.items) |handle| {
            handle.decl_index.deinit(self.gpa);
            handle.tree.deinit(self.gpa);
            self.gpa.free(handle.source_owned);
            self.gpa.free(handle.abs_path);
            self.gpa.destroy(handle);
        }
        self.loaded_handles.deinit(self.gpa);
    }

    /// Returns an existing parsed handle for `abs_path` or parses and caches it.
    ///
    /// `abs_path` should be an absolute path.
    pub fn getOrLoadHandle(self: *LintContext, abs_path: []const u8) !*Handle {
        for (self.loaded_handles.items) |handle| {
            if (std.mem.eql(u8, handle.abs_path, abs_path)) return handle;
        }

        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            abs_path,
            self.gpa,
            .limited(max_zig_file_size_bytes),
            .of(u8),
            0,
        );
        errdefer self.gpa.free(source);

        var source_z = try self.gpa.allocSentinel(u8, source.len, 0);
        errdefer self.gpa.free(source_z);
        @memcpy(source_z[0..source.len], source);
        self.gpa.free(source);

        var tree = try Ast.parse(self.gpa, source_z, .zig);
        errdefer tree.deinit(self.gpa);

        var decl_index = try semantic.DeclIndex.init(tree, self.gpa);
        errdefer decl_index.deinit(self.gpa);

        const handle = try self.gpa.create(Handle);
        errdefer self.gpa.destroy(handle);
        handle.* = .{
            .abs_path = try self.gpa.dupe(u8, abs_path),
            .source_owned = source_z,
            .tree = tree,
            .decl_index = decl_index,
        };
        errdefer self.gpa.free(handle.abs_path);

        try self.loaded_handles.append(self.gpa, handle);
        return handle;
    }

    /// Resolves `import_path` from `importer_abs_path` and memoizes result for
    /// this lint run. Returned handle is loaded in `loaded_handles`.
    pub fn resolveImportHandle(
        self: *LintContext,
        importer_abs_path: []const u8,
        import_path: []const u8,
    ) !?*Handle {
        if (std.mem.eql(u8, import_path, "std")) return null;

        if (self.import_handle_cache.get(.{
            .importer_abs_path = importer_abs_path,
            .import_path = import_path,
        })) |cached| {
            return cached;
        }

        const key = ImportCacheKey{
            .importer_abs_path = try self.gpa.dupe(u8, importer_abs_path),
            .import_path = try self.gpa.dupe(u8, import_path),
        };
        errdefer self.gpa.free(key.import_path);
        errdefer self.gpa.free(key.importer_abs_path);

        var resolved: ?*Handle = null;
        if (self.semantic_ctx.resolveImportPathAlloc(importer_abs_path, import_path, self.gpa)) |abs_path| {
            defer self.gpa.free(abs_path);
            resolved = self.getOrLoadHandle(abs_path) catch |e| switch (e) {
                error.FileNotFound => null,
                else => return e,
            };
        }

        try self.import_handle_cache.put(self.gpa, key, resolved);
        return resolved;
    }

    /// Loads and parses a zig file into a document.
    ///
    /// Caller is responsible for calling `doc.deinit` when done.
    pub fn initDocument(
        self: *LintContext,
        path: []const u8,
        gpa: std.mem.Allocator,
        doc: *LintDocument,
    ) !void {
        var real_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_path_len = try std.Io.Dir.cwd().realPathFile(
            self.io,
            path,
            &real_path_buf,
        );
        const abs_path = real_path_buf[0..abs_path_len];
        const handle = try self.getOrLoadHandle(abs_path);

        var src_comments = try comments.allocParse(handle.tree.source, gpa);
        errdefer src_comments.deinit(gpa);

        doc.* = .{
            .path = try gpa.dupe(u8, path),
            .handle = handle,
            .lineage = .empty,
            .comments = src_comments,
            .skipper = undefined, // set below
        };
        errdefer gpa.free(doc.path);
        errdefer doc.lineage.deinit(gpa);

        doc.skipper = .init(doc.comments, doc.handle.tree.source, gpa);
        errdefer doc.skipper.deinit();

        try buildLineage(doc, gpa);
    }
};

fn buildLineage(doc: *LintDocument, gpa: std.mem.Allocator) !void {
    const tree = &doc.handle.tree;

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

        // Defensive cleanup if a node is somehow visited more than once.
        doc.lineage.get(@intFromEnum(item.node)).deinit(gpa);
        doc.lineage.set(@intFromEnum(item.node), .{
            .parent = if (item.parent) |p| p else null,
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

test "LintDocument.isEnclosedInTestBlock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const environ_map: std.process.Environ.Map = .init(arena.allocator());

    var context: LintContext = undefined;
    try context.init(std.testing.io, &environ_map, std.testing.allocator);
    defer context.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\pub fn main() void {
        \\ const is_not_in_test = 1;
        \\
        \\ if (builtin.is_test) {
        \\  const is_in_test_if_condition_a = 1;
        \\ }
        \\ if (anything.is_test) {
        \\  const is_in_test_if_condition_b = 1;
        \\ }
        \\ if (is_test) {
        \\  const is_in_test_if_condition_c = 1;
        \\ }
        \\ if (something) {
        \\    const is_not_in_test_nested_if_condition_a = 1;
        \\    if (is_test) {
        \\      const is_in_test_nested_if_condition_a = 1;
        \\    }
        \\ }
        \\ if (is_test) {
        \\    const is_in_test_nested_if_condition_c = 1;
        \\    if (something) {
        \\      const is_in_test_nested_if_condition_b = 1;
        \\    }
        \\ }
        \\ if (other) {
        \\  const is_not_in_test_if_condition = 1;
        \\ }
        \\}
        \\
        \\test {
        \\ const is_in_test_without_name = 1;
        \\}
        \\
        \\test "with name" {
        \\ const is_in_test_with_name = 1;
        \\}
    ;

    const doc = try testing.loadFakeDocument(
        &context,
        tmp.dir,
        "test.zig",
        source,
        arena.allocator(),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_without_name",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_a",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_b",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_c",
        )),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test_if_condition",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_a",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_b",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_c",
        )),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test_nested_if_condition_a",
        )),
    );
}

const ast = @import("ast.zig");
const BuildInfo = @import("BuildInfo.zig");
const comments = @import("comments.zig");
const semantic = @import("semantic.zig");
const std = @import("std");
const testing = @import("testing.zig");
const LintProblem = @import("results.zig").LintProblem;
const Ast = std.zig.Ast;

test {
    std.testing.refAllDecls(@This());
}
