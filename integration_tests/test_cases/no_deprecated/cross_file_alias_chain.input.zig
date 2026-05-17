const refs = @import("../../src/test_case_references.zig");
const refs2 = refs;
const StateAlias = refs2.State;

pub fn main() void {
    const data = refs2.MyDeprecatedData{
        .deprecated_field = 1,
        .ok_field = 2,
        .field_with_deprecated_enum = .a,
    };
    _ = data.deprecated_field;

    var state: StateAlias = .really_deprecated;
    _ = state;

    _ = refs2.doNotCallDeprecated();
}
