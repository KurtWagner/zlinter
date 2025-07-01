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
