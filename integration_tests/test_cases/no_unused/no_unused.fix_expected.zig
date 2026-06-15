export const banana = @import("std");
pub const strawberry = @import("std");

const Tomato = struct {};
const Milk = struct {};

pub fn main() !void {
    const cookie = @import("std").ascii;
    _ = cookie;

    const tomato: Tomato = .{};
    tomato.* = undefined;

    const milk = Milk{};
    milk.* = undefined;
}

// zlinter-disable-next-line
const unused_but_disabled = 0;
const also_unused_disabled = 0; // zlinter-disable-current-line

// zlinter-disable-next-line no_unused
const also_explicitly_disabled = 0;

// zlinter-disable-next-line different_rule

// Comment

// Example where referencing root self.
const Self = @This();
const used_by_root_field_so_good = 123;
const also_used_by_root_field_so_good = 321;

pub fn run() void {
    _ = @This().used_by_root_field_so_good;
    _ = Self.also_used_by_root_field_so_good;
}
