const State = enum {
    idle,
    running,
    stopped,
};

const Number = enum(u8) {
    one,
    two,
    three,
    _,
};

pub fn ok_grouped(state: State) void {
    switch (state) {
        .idle => {},
        .running, .stopped => {},
    }
}

pub fn bad_else(state: State) void {
    switch (state) {
        .idle => {},
        .running => {},
        else => {},
    }
}

pub fn bad_multiple(state: State) void {
    switch (state) {
        .idle => {},
        else => {},
    }
}

pub fn non_exhaustive(number: Number) void {
    switch (number) {
        .one => {},
        else => {},
    }
}

pub fn non_enum(x: u32) void {
    switch (x) {
        0 => {},
        else => {},
    }
}

pub fn references() void {
    const Ok = enum { a, b, c, d };
    const b = Ok.a;
    const Other = Ok;

    const value = Ok.d;

    switch (value) {
        b => {},
        Other.b => {},
        .c => {},
        else => {},
    }
}
