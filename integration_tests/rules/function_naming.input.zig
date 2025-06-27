fn this_is_not_ok() void {}

fn ThisIsAlsoNotOk() void {}

fn thisIsOk() void {}

fn ThisIsOk() type {}

fn thisIsNotOk() type {}

pub const Parent = struct {
    fn this_is_not_ok() void {}

    fn ThisIsAlsoNotOk() void {}

    fn thisIsOk() void {}

    fn ThisIsOk() type {}

    fn thisIsNotOk() type {}
};

fn here(Arg: u32, t: type, fn_call: *const fn (A: u32) void) t {
    fn_call(Arg);
    return @intCast(Arg);
}

fn alsoHere(arg: u32, T: type, fnCall: *const fn (a: u32) void) T {
    fnCall(arg);
    return @intCast(arg);
}
