const convention: namespace.CallingConvention = .Stdcall;

const namespace = struct {
    const CallingConvention = enum {
        /// Deprecated: Don't use
        Stdcall, // <-- TODO: fix this bug, this shouldn't be caught - #36
        std_call,
    };
};

/// Deprecated: don't use this
const message = "hello";

/// Deprecated: Just because
pub const MyDeprecatedEnum = enum { a, b };

/// Deprecated - function not good
fn doNothing() void {}

pub const MyStruct = struct {
    /// Deprecated: also not this
    deprecated_field: u32 = 10,
    other_field: u32 = 11,

    state: test_case_references.State = .really_deprecated,

    deprecated_enum_field: MyDeprecatedEnum = .a,

    const deprecated_container_decl: MyDeprecatedEnum = .b;

    /// Deprecated - not good
    pub fn alsoDoNothing(self: MyStruct) u32 {
        return self.deprecated_field;
    }
};

pub fn main() void {
    const data = test_case_references.MyDeprecatedData{
        .deprecated_field = 10,
        .ok_field = 12,
    };

    std.log.err("Message: {s} {d} {d}", .{ message, data.deprecated_field, data.ok_field });

    const indirection = message;
    std.log.err("Message: {s}", .{indirection});

    doNothing();

    var me = MyStruct{ .state = .really_deprecated };
    me = MyStruct{ .state = test_case_references.State.really_deprecated };

    std.log.err("Fields: {d} {d}", .{ me.deprecated_field, me.field_b });

    _ = me.alsoDoNothing();

    std.log.err("Hello {s}", .{test_case_references.doNotCallDeprecated()});
}

const std = @import("std");
const test_case_references = @import("../../src/test_case_references.zig");
