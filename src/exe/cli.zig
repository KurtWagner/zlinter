pub const std_options: std.Options = .{
    .log_level = if (@import("zlinter_build_config").verbose)
        .info
    else
        .err,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = std.heap.smp_allocator;

    var threaded = std.Io.Threaded.init(gpa, .{
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    var printer: *zlinter.rendering.Printer = zlinter.rendering.process_printer;
    printer.init(
        &stdout_writer.interface,
        &stderr_writer.interface,
        try .init(io, std.Io.File.stdout(), init.environ_map),
        false,
    );

    const args = args: {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        break :args zlinter.Args.allocParse(
            try init.minimal.args.toSlice(arena.allocator()),
            &lint_builtin.rules,
            gpa,
        ) catch |e| switch (e) {
            error.InvalidArgs => {
                zlinter.Args.printHelp(printer);
                return ExitCode.usage_error.int();
            },
            error.InvalidBuildConfig => return ExitCode.tool_error.int(),
            error.OutOfMemory => @panic("OOM"),
        };
    };
    defer args.deinit(gpa);

    // Technically a chicken and egg problem as you can't rely on verbose stdout
    // while parsing args, so this would probably be better as a build option
    // but for now this should be fine and keeps args together at runtime...
    printer.verbose = args.verbose;

    if (args.help) {
        zlinter.Args.printHelp(printer);
        return ExitCode.success.int();
    }

    if (args.unknown_args) |unknown_args| {
        for (unknown_args) |arg|
            printer.println(.err, "Unknown argument: {s}", .{arg});
        zlinter.Args.printHelp(printer);
        return ExitCode.usage_error.int();
    }

    var runtime: LintRuntime = .init(io, gpa, &args);
    defer runtime.deinit(gpa);

    const lint_files = try resolveFilesToLint(&runtime, args);

    const exit_code = switch (args.mode) {
        .lint => try lint.run(
            &runtime,
            args,
            printer,
            lint_files,
        ),
        .lsp => try lsp.run(
            &runtime,
            args,
            printer,
            lint_files,
        ),
    };
    return exit_code.int();
}

fn resolveFilesToLint(
    runtime: *const LintRuntime,
    args: zlinter.Args,
) ![]zlinter.files.LintFile {
    var dir = try std.Io.Dir.cwd().openDir(
        runtime.io,
        "./",
        .{ .iterate = true },
    );
    defer dir.close(runtime.io);

    const lint_files = try zlinter.files.allocLintFiles(
        runtime.io,
        dir,
        // User include paths supersede build configured includes/excludes.
        args.include_paths orelse args.build_include_paths orelse null,
        runtime.sessionArena(),
    );

    if (try zlinter.files.buildExcludesIndex(
        runtime.io,
        runtime.sessionArena(),
        dir,
        args,
    )) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = index.contains(file.abs_path);
    }

    if (try zlinter.files.buildFilterIndex(
        runtime.io,
        runtime.sessionArena(),
        dir,
        args,
    )) |*index| {
        defer @constCast(index).deinit();

        for (lint_files) |*file|
            file.excluded = !index.contains(file.abs_path);
    }

    return lint_files;
}

test {
    std.testing.refAllDecls(@This());
}

const common = @import("common.zig");
const lint = @import("mode/lint.zig");
const lsp = @import("mode/lsp.zig");

const lint_builtin = @import("lint_builtin"); // Generated in build_lint_builtin.zig
const std = @import("std");
const zlinter = @import("zlinter");

const ExitCode = common.ExitCode;
const LintRuntime = zlinter.session.LintRuntime;
