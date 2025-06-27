const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .err,
};

test {
    std.testing.refAllDecls(@This());

    var process = std.process.Child.init(
        &.{ "zig", "build", "test" },
        std.testing.allocator,
    );
    process.cwd = "./integration_tests";

    try switch (try process.spawnAndWait()) {
        .Exited => |exit_code| try std.testing.expect(exit_code == 0),
        else => std.testing.expect(false),
    };
}
