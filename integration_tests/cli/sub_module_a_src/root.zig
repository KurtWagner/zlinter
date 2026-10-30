pub const strLen = @import("child.zig").strLen;

pub const Type = enum { a, b, c };

// For declaration naming tests:
pub const EnumType = enum { a };
pub const int_value: u32 = 1;
// zlinter-disable-next-line - should be GetPerson but we need to be consistent with other root implementation
pub fn getPerson(age: u32) type {
    return struct {
        age: u32 = age,
    };
}

// For function naming tests:
pub const CallbackFn = *const fn () void;
pub const TypeFactoryFn = *const fn () type;
pub const SomeTypeAlias = type;
