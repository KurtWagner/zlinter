// zlinter-disable no_undefined - also testing irrelevant rule
pub fn good(x: i32, y: i32) !i32 {
    if (y == 0) return error.DivideByZero;
    return x / y;
}

// zlinter-disable-next-line no_undefined - also testing irrelevant rule
pub fn bad(x: i32, y: i32) i32 {
    if (y == 0) @panic("Divide by zero!");
    return x / y;
}

const std = @import("std");
