//! Serialized object passed to linter execution when using CLI arguments is
//! not technically feasible (or if we want to avoid exposing "internal"
//! APIs to the CLI of zlinter).

const BuildInfo = @This();

pub const ModuleImportEntry = struct {
    scope_id: ?[]const u8 = null,
    import_name: []const u8,
    root_source_path: []const u8,
};

pub const ModuleRootEntry = struct {
    scope_id: []const u8,
    root_dir_path: []const u8,
};

/// Similar to `Args.include_paths` but is populated by the build runner and
/// piped into the zlinter execution.
include_paths: ?[]const []const u8 = null,

/// Similar to `Args.exclude_paths` but is populated by the build runner and
/// piped into the zlinter execution.
exclude_paths: ?[]const []const u8 = null,

/// Mapping of non-relative import names to module root source files emitted
/// from build graph metadata.
module_imports: ?[]const ModuleImportEntry = null,

/// Scope roots used to disambiguate module import mappings by importer path.
module_roots: ?[]const ModuleRootEntry = null,

/// Version of build-info payload schema.
schema_version: u16 = 1,

pub const default: BuildInfo = .{};

pub fn deinit(self: BuildInfo, gpa: std.mem.Allocator) void {
    if (self.exclude_paths) |paths| {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    if (self.include_paths) |paths| {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    if (self.module_imports) |module_imports| {
        for (module_imports) |entry| {
            if (entry.scope_id) |scope_id| gpa.free(scope_id);
            gpa.free(entry.import_name);
            gpa.free(entry.root_source_path);
        }
        gpa.free(module_imports);
    }

    if (self.module_roots) |module_roots| {
        for (module_roots) |entry| {
            gpa.free(entry.scope_id);
            gpa.free(entry.root_dir_path);
        }
        gpa.free(module_roots);
    }
}

pub fn consumeStdinAlloc(
    stdin_reader: *std.Io.Reader,
    gpa: std.mem.Allocator,
    printer: *rendering.Printer,
) error{ OutOfMemory, InvalidArgs }!?BuildInfo {
    const size = stdin_reader.takeInt(usize, .little) catch |e| {
        if (e == error.EndOfStream) return null else {
            printer.println(.err, "Failed to read stdin length: {s}", .{@errorName(e)});
            return error.InvalidArgs;
        }
    };
    var buffer = try gpa.alloc(u8, size + 1);
    @memset(buffer, 0);
    defer gpa.free(buffer);

    stdin_reader.readSliceAll(buffer[0..size]) catch |e| {
        printer.println(.err, "Failed to read stdin content: {s}", .{@errorName(e)});
        return error.InvalidArgs;
    };

    return std.zon.parse.fromSliceAlloc(BuildInfo, gpa, buffer[0..size :0], null, .{
        .ignore_unknown_fields = false,
        .free_on_error = true,
    }) catch |e| {
        switch (e) {
            error.ParseZon => {
                printer.println(.err, "Failed to parse stdin zon content: {s}", .{@errorName(e)});
                return error.InvalidArgs;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    };
}

const rendering = @import("rendering.zig");
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
