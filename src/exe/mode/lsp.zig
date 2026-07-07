//! LSP for zlinter diagnostics (not full language server, use ZLS for that)

pub fn run(
    runtime: *const LintRuntime,
    args: zlinter.Args,
    printer: *zlinter.rendering.Printer,
    lint_files: []const zlinter.files.LintFile,
) !ExitCode {
    _ = args;
    _ = printer;
    _ = lint_files;

    var stdin_buf: [8 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(runtime.io, &stdin_buf);

    var stdout_buf: [8 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(runtime.io, &stdout_buf);

    var server: zlinter.lsp.server.LspServer = .init(
        runtime.sessionArena(),
        &stdin.interface,
        &stdout.interface,
    );
    try server.run();
    return ExitCode.success;
}

const std = @import("std");
const zlinter = @import("zlinter");
const ExitCode = @import("../common.zig").ExitCode;
const lint_builtin = @import("lint_builtin");
const LintConfigStore = @import("../common/LintConfigStore.zig");

const Ast = std.zig.Ast;
const oom = zlinter.allocations.oom;
const LintRuntime = zlinter.session.LintRuntime;
const tracy = zlinter.tracy;
