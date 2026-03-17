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
