//! LSP for zlinter diagnostics (not full language server, use ZLS for that)

pub fn main(init: std.process.Init) !void {
    var stdin_buf: [8 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().reader(init.io, &stdin_buf);

    var stdout_buf: [8 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buf);

    var server: zlinter.lsp.server.LspServer = .init(
        init.gpa,
        &stdin.interface,
        &stdout.interface,
    );
    try server.run();
}

const std = @import("std");
const zlinter = @import("zlinter");
