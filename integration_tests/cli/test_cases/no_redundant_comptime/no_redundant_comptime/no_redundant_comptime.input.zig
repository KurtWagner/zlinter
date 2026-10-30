fn List(comptime T: type) type {
    return struct {};
}

fn add(comptime a: comptime_int, comptime b: comptime_float) void {}

fn mixed(comptime T: type, comptime n: usize, comptime F: comptime_float) void {}

fn ListParens(comptime T: (type)) type {
    return struct {};
}

fn ListMultiline(
    comptime
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
