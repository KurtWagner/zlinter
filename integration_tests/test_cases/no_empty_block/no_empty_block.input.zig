pub fn main() void {
    if (true) {} else {
        // Deliberate
    }

    var i: u32 = 9;
    while (i < 10) : (i += 1) {}

    while (i < 20) {
        i += 1;
    }

    while (i < 30) : (i += 2) {
        // Do nothing.
    }

    for (0..1) |_| {}

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
