const a: enum { a, b, c } = .a;

const switch_a = switch (a) {
    .a => {},
    else => {},
    .b => {},
};

const switch_b = switch (a) {
    .a => {},
    .b => {},
    else => {},
};

const switch_c = switch (a) {
    else => {},
    .a => {},
    .b => {},
};

const switch_d = switch (a) {
    .a, .b => {},
    else => {},
};

const switch_e = switch (a) {
    else => {},
    .a, .b => {},
};

const switch_f = switch (a) {
    .a, .b => {},
    .c => {},
};
