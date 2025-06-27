this_is_ok: enum {
    ok,
    also_ok,
    NotOk,
    notOk,
},
thisIsNotOk: ChildStruct,
ThisIsAlsoNotOk: union {
    ok: u32,
    notOk: f32,
    AlsoNotOk: i32,
    also_ok: u64,
},

const Errors = error{
    OkError,
    notOkError,
    not_ok_error,
};

const ChildStruct = struct {
    this_is_ok: u32,
    thisIsNotOk: u32,
    ThisIsNotOk: u32,
};
