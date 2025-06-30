var apple = @import("std");
export const banana = @import("std");
pub const strawberry = @import("std");
const chocolate = @import("std");

const Tomato = struct {};
const Milk = struct {};
const Coffee = struct {};

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
const not_disabled = 0;

// Comment
const ShouldGoInFix = struct {
    multi: u32,
    line: usize,
};
