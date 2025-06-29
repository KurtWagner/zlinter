/// Deprecated: don't use this
const message = "hello";

/// Deprecated - function not good
fn doNothing() void {}

pub const MyStruct = struct {
    /// Deprecated: also not this
    field_a: u32 = 10,
    field_b: u32 = 11,

    /// Deprecated - not good
    fn alsoDoNothing() void {}
};

pub fn main() void {
    std.log.err("Message: {s}", .{message});

    const indirection = message;
    std.log.err("Message: {s}", .{indirection});

    doNothing();

    const me = MyStruct{};
    std.log.err("Fields: {d} {d}", .{ me.field_a, me.field_b });

    me.alsoDoNothing();
}

const std = @import("std");
