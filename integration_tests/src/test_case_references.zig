//! Contains declarations that can be used in test cases to ensure dependency
//! boundaries are resolved correctly

/// Deprecated: Just because
pub const MyDeprecatedEnum = enum { a, b };

pub const State = enum {
    good,
    bad,
    /// Deprecated - please no more
    really_deprecated,
};

/// Deprecated - Super dooper deprecated
pub const MyDeprecatedData = struct {
    /// Deprecated - big time
    deprecated_field: u32,
    ok_field: i32,

    field_with_deprecated_enum: MyDeprecatedEnum,
};

/// Deprecated: Don't call this
pub fn doNotCallDeprecated() []const u8 {
    return "Why you not listen?";
}
