pub extern fn undocumentedExtern(size: usize) void;

/// Doc comment
pub extern fn documentedExtern(size: usize) void;

/// Doc comment
pub fn documentedFunction() void {
}

pub const value = 1;

test "smoke" {
    const local = 1;
    _ = local;
}
