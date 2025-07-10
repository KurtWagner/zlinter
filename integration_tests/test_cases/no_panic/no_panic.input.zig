pub fn good(x: i32, y: i32) !i32 {
    if (y == 0) return error.DivideByZero;
    return x / y;
}

pub fn bad(x: i32, y: i32) i32 {
    if (y == 0) @panic("Divide by zero!");
    return x / y;
}

const std = @import("std");
