const Renderer = @import("regression_value_kind_import_helper.zig");

const Thing = struct {
    const Self = @This();

    field: u32,
};

const Choice = enum {
    alpha,
    beta,
};

const good_instance: Thing = .{ .field = 1 };
var another_instance: Thing = .{ .field = 2 };
const good_choice: Choice = .alpha;
var another_choice: Choice = .beta;
var renderer: Renderer = .{ .field = 3 };

fn run() void {
    var output: Renderer = .{ .field = 4 };
    _ = output;
}
