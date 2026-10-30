fn IntToFloatType(IntType: type) type {
    return @Int(
        .signed,
        @typeInfo(IntType).float.bits,
    );
}

const GoodFloatType = IntToFloatType(u32);
const badFloatType = IntToFloatType(u32);
const bad_float_type = IntToFloatType(u32);

const GoodInt = std.math.IntFittingRange(0, 10);
const badInt = std.math.IntFittingRange(0, 10);
const bad_int = std.math.IntFittingRange(0, 10);

const GoodBitSet = std.bit_set.Static(10);
const badBitSet = std.bit_set.Static(10);
const bad_bit_set = std.bit_set.Static(10);

const std = @import("std");
