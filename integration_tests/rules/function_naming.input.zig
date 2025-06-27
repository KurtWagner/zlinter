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
