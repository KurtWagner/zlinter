//! LSP for zlinter diagnostics (not full language server, use ZLS for that)

pub fn run(
    runtime: *const LintRuntime,
    _: zlinter.Args,
    _: *zlinter.rendering.Printer,
    // TODO: Check if in here before linting?
    _: []const zlinter.files.LintFile,
) !ExitCode {
    var stdin_buf: [8 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(runtime.io, &stdin_buf);

    var stdout_buf: [8 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(runtime.io, &stdout_buf);

    var session: zlinter.session.LintSession = .{
        .runtime = runtime,
        .file_store = .init(runtime),
        .module_store = .init(runtime),
        .build_config_store = .init(runtime),
        .type_store = .init(runtime),
        .decl_store = .init(runtime),
    };
    try session.init();

    var server: zlinter.lsp.server.LspServer = .init(
        runtime,
        &session,
        &stdin.interface,
        &stdout.interface,
        lint_builtin.rules[0..],
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
