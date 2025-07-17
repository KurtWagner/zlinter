export fn parse(in: [*]u8, len: u32) u32 {
    comptime if (!builtin.cpu.arch.isWasm()) {
        @compileError("Wasm only");
    };

    const allocator = std.heap.wasm_allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const source: [:0]const u8 = std.mem.sliceTo(in[0..len :0], 0);

    const json = zlinter.explorer.parseToJsonStringAlloc(source, arena.allocator()) catch @panic("OOM");

    for (json, 0..) |c, i| {
        in[len + i] = c;
    }
    return json.len;
}

const builtin = @import("builtin");
const std = @import("std");
const zlinter = @import("zlinter");
