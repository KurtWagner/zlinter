const apple = @import("apple");
const banana = @import("banana");
const appricot = @import("appricot");

// import_order checks per scope, so although this chunk has the wrong order
// it won't be detected until the issues in the above chunk are fixed first.
const zebra = @import("zebra");
const cat = @import("cat");

pub fn main() void {
    const banana_main = @import("apple_main");
    const apple_main = @import("apple_main");

    _ = banana_main;
    _ = apple_main;
}

pub const namespace = struct {
    const banana_namespace = @import("apple_namespace");
    const apple_namespace = @import("apple_namespace");
};

pub const member_access = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").CEnum;
    const BStruct = @import("BStruct.zig");
};

pub const nested_members = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").parent.child.CEnum;
    const BStruct = @import("BStruct.zig");
};

pub const optional_unwrap = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").value.?;
    const BStruct = @import("BStruct.zig");
};

pub const optional_between_members = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").parent.?.child.CEnum;
    const BStruct = @import("BStruct.zig");
};

pub const function_call = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").make();
    const BStruct = @import("BStruct.zig");
};

pub const call_between_members = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").parent.make().child;
    const BStruct = @import("BStruct.zig");
};

pub const call_and_optional_unwrap = struct {
    const AStruct = @import("AStruct.zig");
    const CEnum = @import("c_enum.zig").parent.make().?.child;
    const BStruct = @import("BStruct.zig");
};

// Runtime initializers must keep their dependency order when applying fixes.
pub fn local_call_dependency() void {
    const z = @import("factory.zig").make();
    const a = @import("factory.zig").consume(z);
    _ = a;
}
