pub const server = @import("lsp/server.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
