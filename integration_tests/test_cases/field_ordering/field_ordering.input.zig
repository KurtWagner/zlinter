const MyStruct = struct {
    const decl_also = 2;
    const decl = 1;

    field_d: u32 = 0,

    /// Field with comment
    /// across multiple
    /// lines
    field_a: u32,

    /// Field with single line comment
    field_c: u32,

    fn ok() void {}
};

const MyEnum = enum {
    /// Comment on single line
    my_enum_d,
    my_enum_a,
    /// Multiline line
    /// comment for enum c
    my_enum_c,
};

const MyUnion = union {
    my_union_a: struct {
        /// Nested fields
        c: f32,
        d: u32,
        a: u32,
    },

    /// With doc comments
    /// on multiple lines
    my_union_c: f32,

    my_union_b: u32,
};

const MyError = error{
    error_d,
    /// Single line
    error_a,
    /// Multi
    /// line
    error_c,
};
