/// Deprecated: Use stringLength instead.
pub fn strLen(str: []const u8) u32 {
    return stringLength(str);
}

pub fn stringLength(str: []const u8) u32 {
    return @intCast(str.len);
}
