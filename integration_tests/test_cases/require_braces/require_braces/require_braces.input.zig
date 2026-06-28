pub fn main() void {
    var val: u32 = 0;

    // If statements:
    if (val < 10) val += 1;
    // zig fmt: off
    if (val < 10) { val += 1; }
    // zig fmt: on
    if (val < 10) {
        val += 1;
    }
    if (val < 10)
        val += 1
    else if (val < 10) {
        val += 1;
        val += 1;
    } else {
        val += 1;
    }

    // While statements:
    while (val < 10) val += 1;
    // zig fmt: off
    while (val < 10) { val += 1; }
    // zig fmt: on
    while (val < 10) {
        val += 1;
    }
    while (val < 10)
        val += 1;
    while (val < 10) {
        val += 1;
        val += 1;
    }

    // For statements:
    for (0..1) |i| val += i;
    // zig fmt: off
    for (0..1) |i| { val += i; }
    // zig fmt: on
    for (0..1) |i| {
        val += i;
    }
    for (0..1) |i|
        val += i;
    for (0..1) |i| {
        val += i;
        val += i;
    }

    // Defer
    defer {
        val = 0;
    }
    defer val = 1;
    defer {
        val = 1;
        val = 2;
    }
    // zig fmt: off
    defer { val = 1; }
    // zig fmt: on

    // Switch
    switch (val) {
        0 => val = 1,
        1 => {
            val = 2;
        },
        2 => {
            val = 3;
            val = 4;
        },
        // zig fmt: off
        3 => { val = 5; },
        // zig fmt: on
        4 => {},
        else => {},
    }
}
