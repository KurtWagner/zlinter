pub fn pubBad() !void {
    return error.Always;
}

pub fn pubGood() error{Always}!void {
    return error.Always;
}

const Errors = error{Always};

pub fn pubAlsoGood() Errors!void {
    return error.Always;
}

pub fn pubAlsoAllowedByDefault() anyerror!void {
    return error.Always;
}

pub fn hasNoError() void {}

fn privateAllowInferred() !void {
    return error.Always;
}
