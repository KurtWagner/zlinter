const Struct = struct {
    x: u32, // Ok - excluded
    b: u32, // Too short
    bb: u32, // Too short,
    ooo: u32, // Ok
    oooo: u32, // Ok
    ooooooo: u32, // Ok
    bbbbbbbb: u32, // Too long,
    xxxxxxxx: u32, // Ok excluded
};

// No names so no length checks
const Tuple = struct {
    u32,
    u8,
};

const Union = union {
    x: u32, // Ok - excluded
    b: u32, // Too short
    oo: u32, // Ok
    ooo: u32, // Ok
    bbbb: u32, // Too long,
    xxxx: u32, // Ok - excluded
};

const Enum = enum {
    x, // Ok - excluded
    b, // Too short
    bb, // Too short,
    ooo, // Ok
    oooo, // Ok
    ooooo, // Ok
    bbbbbb, // Too long,
    xxxxxx, // Ok - excluded
};

const Error = error{
    X, // Ok - excluded
    B, // Too short
    OO, // OK
    BBB, // Too long
    XXX, // Ok - excluded
};
