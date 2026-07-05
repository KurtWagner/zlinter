//! Used for rendering results to stdout

pub const DefaultFormatter = @import("./formatters/DefaultFormatter.zig");
pub const Formatter = @import("./formatters/Formatter.zig");

const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
