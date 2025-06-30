fn goodFn() void {}
fn BadFn() void {}
fn bad_fn() void {}

fn GoodFnType() type {
    return u32;
}
fn bad_fn_type() type {
    return u32;
}
fn badFnType() type {
    return u32;
}

fn goodFnTypeGeneric(T: type) T {
    return T;
}
fn bad_fn_typeGeneric(T: type) T {
    return T;
}
fn BadFnTypeGeneric(T: type) T {
    return u32;
}

// In nested namespace:
pub const Parent = struct {
    fn goodFn() void {}
    fn BadFn() void {}
    fn bad_fn() void {}

    fn GoodFnType() type {
        return u32;
    }
    fn bad_fn_type() type {
        return u32;
    }
    fn badFnType() type {
        return u32;
    }
};

// Function args
fn exampleA(good_int: u32, BadInt: u32, badInt: u32) void {
    _ = good_int;
    _ = BadInt;
    _ = badInt;
}

const int_val: u32 = 10;
fn exampleB(GoodType: type, bad_type: type, badType: @TypeOf(int_val)) void {
    _ = GoodType;
    _ = bad_type;
    _ = badType;
}

const goodFn = *const fn () void{};
fn exampleC(goodFn: *const fn () void, bad_fn: fn () void, BadFn: goodFn) void {
    _ = goodFn;
    _ = bad_fn;
    _ = BadFn;
}

const goodFnType = *const fn () type{};
fn exampleD(GoodFn: *const fn () type, bad_fn: fn () type, badFn: goodFnType) void {
    _ = GoodFn;
    _ = bad_fn;
    _ = badFn;
}

// Should ignore "_"
fn exampleE(_: goodFn) void {}

// Function of function args
fn exampleF(_: *const fn (good_int: u32, GoodType: type, goodFn: fn () void) void) void {}
fn exampleG(_: *const fn (badInt: u32, bad_type: type, BadFn: fn () void) void) void {}
