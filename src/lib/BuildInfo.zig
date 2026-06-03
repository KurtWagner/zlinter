//! Serialized object passed to linter execution when using CLI arguments is
//! not technically feasible (or if we want to avoid exposing "internal"
//! APIs to the CLI of zlinter).

const BuildInfo = @This();

/// Similar to `Args.include_paths` but is populated by the build runner and
/// piped into the zlinter execution.
include_paths: ?[]const []const u8 = null,

/// Similar to `Args.exclude_paths` but is populated by the build runner and
/// piped into the zlinter execution.
exclude_paths: ?[]const []const u8 = null,

/// Compile contexts from the build runner.
///
/// These describe the Zig module graph that was available to each compile
/// step. Lint rules can use this to resolve named imports in the same context
/// as the compiler.
compiles: ?[]const Compile = null,

pub const ModuleIndex = u32;

pub const Compile = struct {
    name: []const u8,
    step_name: []const u8,
    kind: std.Build.Step.Compile.Kind,
    modules: []const Module,

    /// Index in Compile.modules[].
    root_module: ModuleIndex,
};

pub const Module = struct {
    /// Name used to reach this module from the compile graph. The root module
    /// is always named "root".
    name: []const u8,
    /// Absolute path to the module root source file, or null when the module
    /// does not have a source file that can be opened by the lint process,
    /// e.g. generated code that has not been materialized yet.
    root_source_file: ?[]const u8,
    imports: []const Import,
};

pub const Import = struct {
    name: []const u8,

    /// Index in Compile.modules[]
    module: ModuleIndex,
};

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

    if (self.compiles) |compiles| {
        for (compiles) |compile| {
            gpa.free(compile.name);
            gpa.free(compile.step_name);

            for (compile.modules) |module| {
                gpa.free(module.name);
                if (module.root_source_file) |root_source_file| {
                    gpa.free(root_source_file);
                }

                for (module.imports) |import| {
                    gpa.free(import.name);
                }
                gpa.free(module.imports);
            }
            gpa.free(compile.modules);
        }
        gpa.free(compiles);
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
