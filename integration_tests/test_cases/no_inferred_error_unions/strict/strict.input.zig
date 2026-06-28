fn privateBad() !void {
    return error.Bad;
}

pub fn anyerrorBad() anyerror!void {
    return error.Bad;
}

pub fn explicitOk() error{Bad}!void {
    return error.Bad;
}
