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

pub fn isImportBuiltinCall(tree: Ast, node: Ast.Node.Index) bool {
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

pub fn writeImportPath(
    tree: Ast,
    node: Ast.Node.Index,
    buffer: *[std.fs.max_path_bytes]u8,
) ?[]const u8 {
    if (!isImportBuiltinCall(tree, node)) return null;

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

pub fn resolveFile(
    file_store: *FileStore,
    module_store: *const ModuleStore,
    io: std.Io,
    gpa: std.mem.Allocator,
    zig_lib_directory: []const u8,
    parent_file_id: FileStore.FileId,
    import_path: []const u8,
) !?FileStore.FileId {
    const parent_abs_path = file_store.fileAbsPath(parent_file_id);
    const parent_file_dir = std.fs.path.dirname(parent_abs_path) orelse ".";

    return switch (Kind.init(import_path)) {
        .relative => try file_store.resolve(
            import_path,
            io,
            gpa,
            parent_file_dir,
        ),
        .stdlib => try file_store.resolveStdlib(
            io,
            gpa,
            zig_lib_directory,
        ),
        // TODO: #149 - handle "root" and "builtin" imports.
        .builtin,
        .root,
        => null,
        .module => id: {
            const parent_module_id = module_store.moduleIdByRootFile(parent_file_id) orelse break :id null;
            const imported_module_id = module_store.moduleIdByImportName(
                parent_module_id,
                import_path,
            ) orelse break :id null;
            break :id module_store.rootFileId(imported_module_id);
        },
    };
}

const Ast = std.zig.Ast;
const FileStore = @import("FileStore.zig");
const ModuleStore = @import("ModuleStore.zig");
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
