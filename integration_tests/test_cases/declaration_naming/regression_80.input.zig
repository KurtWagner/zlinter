const SomePackedType = packed struct(u32) {
    a: u16 = 0,
    b: u16 = 0,
};
const GoodType = @typeInfo(SomePackedType).@"struct".backing_integer.?;
const badType = @typeInfo(SomePackedType).@"struct".backing_integer.?;
const bad_type = @typeInfo(SomePackedType).@"struct".backing_integer.?;
const BAD_TYPE = @typeInfo(SomePackedType).@"struct".backing_integer.?;
