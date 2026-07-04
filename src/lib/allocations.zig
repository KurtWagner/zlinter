// TODO: Zig 0.17 removed @Type but never added an @ErrorSet replacement so
// unfortunately can't remove "OutOfMemory" from an error set automagically
// at comptime, so for now the API will simply only work when OutOfMemory is
// the only possible error.
fn ErrorUnionPayload(T: type) type {
    return switch (@typeInfo(T)) {
        .error_union => |eu| eu.payload,
        inline else => |e| @compileError(std.fmt.comptimePrint("expected error union, not {t}", .{e})),
    };
}

/// Will panic if return type is `error.OutOfMemory`.
pub fn oom(value: anytype) ErrorUnionPayload(@TypeOf(value)) {
    return value catch |err| switch (err) {
        error.OutOfMemory => @panic("OOM"),
    };
}

const std = @import("std");
