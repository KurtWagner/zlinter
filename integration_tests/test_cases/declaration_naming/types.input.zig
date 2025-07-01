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
