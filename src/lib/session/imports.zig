pub const Kind = enum(u5) {
    relative = 0,
    stdlib = 1,
    root = 2,
    builtin = 3,
    module = 4,

    pub fn init(import_path: []const u8) Kind {
        return if (std.mem.endsWith(u8, import_path, ".zig") and !std.fs.path.isAbsolute(import_path))
            .relative
        else if (std.mem.eql(u8, import_path, "std"))
            .stdlib
        else if (std.mem.eql(u8, import_path, "root"))
            .root
        else if (std.mem.eql(u8, import_path, "builtin"))
            .builtin
        else
            .module;
    }
};

test "Kind.init - relative import path" {
    try std.testing.expectEqual(
        Kind.relative,
        Kind.init("src/session/imports.zig"),
    );
    try std.testing.expectEqual(
        Kind.relative,
        Kind.init("./session/imports.zig"),
    );
    try std.testing.expectEqual(
        Kind.relative,
        Kind.init("./imports.zig"),
    );
    try std.testing.expectEqual(
        Kind.relative,
        Kind.init("imports.zig"),
    );
}

test "Kind.init - stdlib import path" {
    try std.testing.expectEqual(
        Kind.stdlib,
        Kind.init("std"),
    );
}

test "Kind.init - root import path" {
    try std.testing.expectEqual(
        Kind.root,
        Kind.init("root"),
    );
}

test "Kind.init - builtin import path" {
    try std.testing.expectEqual(
        Kind.builtin,
        Kind.init("builtin"),
    );
}

test "Kind.init - absolute or other is module" {
    try std.testing.expectEqual(
        Kind.module,
        Kind.init("/tmp/imports"),
    );
    try std.testing.expectEqual(
        Kind.module,
        Kind.init("imports"),
    );
}

pub fn writeImportPath(
    tree: Ast,
    node: Ast.Node.Index,
    buffer: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    if (!ast.isBuiltinCallNamed(tree, node, "@import")) return null;

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

test "writeImportPath - parses string literal import path" {
    const source: [:0]const u8 =
        \\const value = @import("pkg/module.zig");
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const node = try testing.expectSingleNodeOfTag(
        tree,
        &.{.builtin_call_two},
    );
    const path = writeImportPath(tree, node, &buffer);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("pkg/module.zig", path.?);
}

test "writeImportPath - parses trailing comma builtin call" {
    const source: [:0]const u8 =
        \\const value = @import("pkg/module.zig",);
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const node = try testing.expectSingleNodeOfTag(
        tree,
        &.{.builtin_call_two_comma},
    );
    const path = writeImportPath(tree, node, &buffer);
    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("pkg/module.zig", path.?);
}

test "writeImportPath - rejects non-string import arguments" {
    const source: [:0]const u8 =
        \\const value = @import(123);
    ;

    var tree = try Ast.parse(std.testing.allocator, source, .zig);
    defer tree.deinit(std.testing.allocator);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const node = try testing.expectSingleNodeOfTag(
        tree,
        &.{.builtin_call_two},
    );
    try std.testing.expect(writeImportPath(tree, node, &buffer) == null);
}

pub const ResolveContext = struct {
    file_store: *FileStore,
    module_store: *const ModuleStore,
    parent_file_id: FileStore.FileId,

    /// Root source file for the active semantic module context.
    root_file_id: ?FileStore.FileId,

    pub fn withParent(self: ResolveContext, parent_file_id: FileStore.FileId) ResolveContext {
        return .{
            .file_store = self.file_store,
            .module_store = self.module_store,
            .parent_file_id = parent_file_id,
            .root_file_id = self.root_file_id,
        };
    }
};

/// Resolves an `@import` path in the supplied context.
///
/// `@import("root")` resolves only when `context.root_file_id` is known.
/// Callers should pass the compile context root file directly instead of
/// searching for it from `context.parent_file_id`.
pub fn resolveFile(
    context: ResolveContext,
    import_path: []const u8,
) !?FileStore.FileId {
    const parent_file_id = context.parent_file_id;
    const parent_abs_path = context.file_store.fileAbsPath(parent_file_id);
    const parent_file_dir = std.fs.path.dirname(parent_abs_path) orelse ".";

    return switch (Kind.init(import_path)) {
        .relative => try context.file_store.resolveFrom(
            import_path,
            parent_file_dir,
        ),
        .stdlib => try context.file_store.resolveStdlib(),
        // TODO: #149 - handle "builtin" imports.
        .builtin,
        => null,
        .root,
        => context.root_file_id,
        .module => id: {
            const parent_module_id = context.module_store.moduleIdByRootFile(parent_file_id) orelse break :id null;
            const imported_module_id = context.module_store.moduleIdByImportName(
                parent_module_id,
                import_path,
            ) orelse break :id null;
            break :id context.module_store.rootFileId(imported_module_id);
        },
    };
}

test "resolveFile - root import uses supplied root file id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var file_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer file_arena.deinit();
    var rule_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rule_arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.writeFile(tmp.dir, "root.zig", "");
    try testing.writeFile(tmp.dir, "child.zig", "");

    var root_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_path = root_path_buffer[0..try tmp.dir.realPathFile(
        std.testing.io,
        "root.zig",
        &root_path_buffer,
    )];

    var child_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const child_path = child_path_buffer[0..try tmp.dir.realPathFile(
        std.testing.io,
        "child.zig",
        &child_path_buffer,
    )];

    var runtime: LintRuntime = .{
        .io = std.testing.io,
        .verbose = false,
        .session_arena = &arena,
        .file_arena = &file_arena,
        .rule_arena = &rule_arena,
        .zig_exe = "zig",
        .zig_lib_directory = ".",
        .cwd = ".",
    };
    var file_store: FileStore = .init(&runtime);
    var module_store: ModuleStore = .init(&runtime);

    const compile_root_file_id = try file_store.resolve(
        root_path,
    );
    const child_file_id = try file_store.resolve(
        child_path,
    );

    const resolved_compile_root_file_id = try resolveFile(
        .{
            .file_store = &file_store,
            .module_store = &module_store,
            .parent_file_id = child_file_id,
            .root_file_id = compile_root_file_id,
        },
        "root",
    );
    try std.testing.expectEqual(compile_root_file_id, resolved_compile_root_file_id.?);

    const unresolved_compile_root_file_id = try resolveFile(
        .{
            .file_store = &file_store,
            .module_store = &module_store,
            .parent_file_id = child_file_id,
            .root_file_id = null,
        },
        "root",
    );
    try std.testing.expectEqual(@as(?FileStore.FileId, null), unresolved_compile_root_file_id);
}

const Ast = std.zig.Ast;
const FileStore = @import("FileStore.zig");
const LintRuntime = @import("LintRuntime.zig");
const ModuleStore = @import("ModuleStore.zig");
const ast = @import("../ast.zig");
const testing = @import("../testing.zig");
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
