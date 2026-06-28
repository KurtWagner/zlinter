/// Deprecated: Use stringLength instead.
pub fn strLen(str: []const u8) u32 {
    return stringLength(str);
}

pub fn stringLength(str: []const u8) u32 {
    return @intCast(str.len);
}

pub const Type = enum { a, x };

// For declaration naming tests:
pub const EnumType = enum { a };
pub const int_value: u32 = 1;
pub const Person = struct { age: u32 };
pub fn getPerson(age: u32) Person {
    return .{ .age = age };
}

// For function naming tests:
pub const CallbackFn = *const fn () void;
pub const TypeFactoryFn = *const fn () type;
pub const SomeTypeAlias = type;
