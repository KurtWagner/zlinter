fn List(T: type) type {
    return struct {};
}

fn add(a: comptime_int, b: comptime_float) void {}

fn mixed(T: type, comptime n: usize, F: comptime_float) void {}

fn ListParens(T: (type)) type {
    return struct {};
}

fn ListMultiline(
    T: type,
) type {
    return struct {};
}

fn ListComment(
    comptime // intentionally weird formatting
    T: type,
) type {
    return struct {};
}
