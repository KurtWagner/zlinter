const SomePackedType = packed struct(u32) {
    abc: u16 = 0,
    bcd: u16 = 0,
};
const GoodType = @typeInfo(SomePackedType).@"struct".backing_integer.?;
const badType = @typeInfo(SomePackedType).@"struct".backing_integer.?;
const bad_type = @typeInfo(SomePackedType).@"struct".backing_integer.?;
const BAD_TYPE = @typeInfo(SomePackedType).@"struct".backing_integer.?;
