pub fn main() void {
    if (true) {} else {
        // Deliberate
    }

    if (false) {
        return;
    } else {}

    var i: u32 = 9;
    while (i < 10) : (i += 1) {} else {}

    while (i < 20) {
        i += 1;
    } else {}

    while (i < 30) : (i += 2) {
        // Do nothing.
    }

    for (0..1) |_| {} else {}

    for (0..1) |_| {
        continue;
    } else {}

    defer {}
    defer {
        // TODO: sample todo
    }
    errdefer {}
    errdefer {
        // Empty because I can
    }

    const value: enum { a, b, c } = .a;
    switch (value) {
        .a => {},
        .b => {
            // Do nothing
        },
        else => {},
    }
}

pub fn emptyFn() void {}

pub fn alsoEmptyFn() void {
    // This is ok.
}

test {}

test "name" {}

test "comment only" {
    // deliberate
}

comptime {}

comptime {
    // deliberate
}

pub fn nestedMain() void {
    const items = [_]u8{1};
    if (true) if (true) {} else {};
    while (true) if (true) {} else {};
    for (items) |_| if (true) {} else {};
}
