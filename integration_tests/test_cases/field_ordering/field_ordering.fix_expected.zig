const MyStruct = struct {
    const decl_also = 2;
    const decl = 1;

    field_d: u32 = 0,

    /// field_c - field with single line comment
    field_c: u32,

    /// field_a - Field with comment
    /// across multiple
    /// lines
    field_a: u32,

    fn ok() void {}
};

const MyEnum = enum {
    my_enum_a,
    /// my_enum_c - Multiline line
    /// comment for enum c
    my_enum_c,
    /// my_enum_d - Comment on single line
    my_enum_d,
};

const MyUnion = union {
    my_union_a: struct {
        d: u32,
        /// c - Nested fields
        c: f32,
        a: u32,
    },

    my_union_b: u32,

    /// my_union_c - With doc comments
    /// on multiple lines
    my_union_c: f32,
};

// TODO: Support errors in field ordering?
const MyError = error{
    error_d,
    /// error_a - Single line
    error_a,
    /// error_c - Multi
    /// line
    error_c,
};
