const MyStruct = struct {
    const decl_also = 2;
    const decl = 1;

    field_d: u32 = 0,

    /// Field a comment
    /// multiue line
    field_a: u32,

    /// Field c comment sing;e
    field_c: u32,

    fn ok() void {}
};

const MyEnum = enum {
    /// Doc comment on single line
    my_enum_d,
    my_enum_a,
    /// Doc comment on. multiline
    /// multiline
    my_enum_c,
};

const MyUnion = union {
    my_union_a: struct {
        field: u32,
    },

    /// With doc comments
    /// on mjltiple lines
    my_union_c: f32,

    my_union_b: u32,
};

const MyError = error{
    error_d,
    /// SIngle line
    error_a,
    /// Multi
    /// line
    error_c,
};
