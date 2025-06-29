// Structs that aren't namespaces
const MyGoodStruct = struct { a: u32 };
const myBadStruct = struct { a: u32 };
const my_bad_struct = MyGoodStruct;

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

// TODO: Fix this?
// var GoodOptionalType: ?type = null;
