pub var BadName = 10;
pub var BadNameAgain: u32 = undefined;
pub var GoodOne: ?type = null;
pub var GoodOneAgain: ?type = null;

pub var MyStruct = struct {
    good_name: u32,
    BadName: u32,
    OkName: type,
    AnotherOkName: ?type,
    YetAnotherOkName: ?type = null,
    badName: []u8,
    AnotherBadOne: type = undefined,
    gameDraw: *const fn () void = undefined,
};

pub const MyGoodEnum = struct { a, a_b };
pub const MyBadEnum = struct { A };
pub const MyBadEnumAgain = struct { aB };

pub var gameDraw: *const fn () void = undefined;
pub var badNum: u32;
pub var anotherBadNum: u32 = 10;
pub var YetAnotherBadNum: usize = 10;
