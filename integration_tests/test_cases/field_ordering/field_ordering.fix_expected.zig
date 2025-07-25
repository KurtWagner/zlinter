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

// Example with no trailing comma for an item that is moved to start
const EnumOfOneLine = enum { A, C, D };
const UnionOfOneLine = union { A: i32, C: u32, D: f32 };
const StructOfOnLine = struct { b: u32, a: u32 };

// Example where fixes overlap so aren't included - needs multiple fix calls
const MixedStruct = struct {
    d: u32,
    c: struct { x: u32, y: u32, w: u32, h: u32 },
    b: struct { w: u32, h: u32 },
    a: []const u8,
};

// Example where only nested has ordering problem
const NestedStruct = struct {
    d: u32,
    c: struct { y: u32, x: u32, w: u32, h: u32 },
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

// Structs are off by default so these should be ignored
const Packed = packed struct(u64) {
    b: u32,
    a: u32,
};

const Extern = extern struct {
    b: u32,
    a: u32,
};

const Normal = struct {
    b: u32,
    a: u32,
};
