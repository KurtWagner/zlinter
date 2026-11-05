const Example = packed struct(u32) { value: u32 };
const metadata = @typeInfo(Example);
const field_count = @typeInfo(Example).Struct.fields.len;
const tuple_flag = @typeInfo(Example).Struct.is_tuple;
const FieldCount = @typeInfo(Example).Struct.fields.len;
