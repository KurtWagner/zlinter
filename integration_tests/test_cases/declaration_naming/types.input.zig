// Structs that aren't namespaces
const MyGoodStruct = struct { a: u32 };
const myBadStruct = struct { a: u32 };
const my_bad_struct = MyGoodStruct;
const myBadOptionalStruct: ?type = struct { a: u32 };
const my_bad_optional_struct: ?type = struct { a: u32 };

const MyGoodEnum = enum { a, b };
const myBadEnum = enum { a, b };
const my_bad_enum = MyGoodEnum;

const MyGoodUnion = union { a: u32, b: u64 };
const myBadUnion = union(enum) { a: u32, b: u64 };
const my_bad_union = MyGoodUnion;

// Types vs others
var BadInt = 10;
var badInt = 10;
var good_int = 10;
var good_optional_int: ?u32 = null;
var badType = u32;
var bad_type = @TypeOf(badType);
var GoodType = u32;

var GoodOptionalType: ?type = null;
var badOptionalType: ?type = null;
var bad_optional_type: ?type = null;

// Typeof anytype
pub inline fn anytypeSampleA(in: anytype) struct { type, type, type } {
    const GoodAnyType = @TypeOf(in);
    const badAnyType = @TypeOf(in);
    const bad_any_type = @TypeOf(in);
    return .{ GoodAnyType, badAnyType, bad_any_type };
}

// Errors
const MyGoodError = error{ ErrorA, ErrorB };
const myBadError = error{ ErrorA, ErrorB };
const my_bad_error = MyGoodError;

// Error merge sets (considered errors thus types)
const AlsoMyGoodError = MyGoodError || my_bad_error;
const alsoMyBadError = MyGoodError || my_bad_error;
const also_my_bad_error = MyGoodError || my_bad_error;

// Extern are excluded by default
extern const BadExtern: u32;
extern const badExtern: u32;
extern const good_extern: u32;

// Exports are included by default
export const BadExport: u32 = 10;
export const badExport: u32 = 10;
export const good_export: u32 = 10;

// Aliases are excluded by default
const system = struct {
    const FAILURE: u32 = 1; // zlinter-disable-current-line
    const nested = struct {
        const Uint: u32 = 10; // zlinter-disable-current-line
    };
};

const FAILURE = system.FAILURE;
pub const Uint = system.nested.Uint;
const NOT_ALIAS = system.FAILURE;
