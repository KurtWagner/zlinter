const MyStruct = struct {
    const decl_also = 2;
    const decl = 1;

    field_d: u32 = 0,

    /// field_a - Field with comment
    /// across multiple
    /// lines
    field_a: u32,

    /// field_c - field with single line comment
    field_c: u32,

    fn ok() void {}
};

const MyEnum = enum {
    /// my_enum_d - Comment on single line
    my_enum_d,
    my_enum_a,
    /// my_enum_c - Multiline line
    /// comment for enum c
    my_enum_c,
};

const MyUnion = union {
    my_union_a: struct {
        /// c - Nested fields
        c: f32,
        d: u32,
        a: u32,
    },

    /// my_union_c - With doc comments
    /// on multiple lines
    my_union_c: f32,

    my_union_b: u32,
};

// Example with no trailing comma for an item that is moved to start
const EnumOfOneLine = enum { D, C, A };
const UnionOfOneLine = union { D: f32, C: u32, A: i32 };
const StructOfOnLine = struct { a: u32, b: u32 };

// Example where fixes overlap so aren't included - needs multiple fix calls
const MixedStruct = struct {
    a: []const u8,
    c: struct { x: u32, y: u32, w: u32, h: u32 },
    b: struct { w: u32, h: u32 },
    d: u32,
};

// Example where only nested has ordering problem
const NestedStruct = struct {
    d: u32,
    c: struct { x: u32, y: u32, w: u32, h: u32 },
    b: struct { w: u32, h: u32 },
    a: []const u8,
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
