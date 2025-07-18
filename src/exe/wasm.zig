/// Consumes `len` bytes from given `buffer`, parses it into a Zig AST json
/// string and then writes it back to the start of the given `buffer` returning
/// the length.
export fn parse(buffer: [*]u8, len: u32) u32 {
    comptime if (!builtin.cpu.arch.isWasm()) @compileError("Wasm only");

    var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
    defer arena.deinit();

    const source: [:0]const u8 = arena.allocator().dupeZ(u8, buffer[0..len]) catch @panic("OOM");
    const json = zlinter.explorer.parseToJsonStringAlloc(source, arena.allocator()) catch @panic("OOM");

    @memcpy(buffer, json);
    return json.len;
}

const builtin = @import("builtin");
const std = @import("std");
const zlinter = @import("zlinter");
