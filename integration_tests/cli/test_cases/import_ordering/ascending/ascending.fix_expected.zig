const apple = @import("apple");
const appricot = @import("appricot");
const banana = @import("banana");

const cat = @import("cat");
// import_order checks per scope, so although this chunk has the wrong order
// it won't be detected until the issues in the above chunk are fixed first.
const zebra = @import("zebra");

pub fn main() void {
    const apple_main = @import("apple_main");
    const banana_main = @import("apple_main");

    _ = banana_main;
    _ = apple_main;
}

pub const namespace = struct {
    const apple_namespace = @import("apple_namespace");
    const banana_namespace = @import("apple_namespace");
};

pub const member_access = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").CEnum;
};

pub const nested_members = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").parent.child.CEnum;
};

pub const optional_unwrap = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").value.?;
};

pub const optional_between_members = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").parent.?.child.CEnum;
};

pub const function_call = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").make();
};

pub const call_between_members = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").parent.make().child;
};

pub const call_and_optional_unwrap = struct {
    const AStruct = @import("AStruct.zig");
    const BStruct = @import("BStruct.zig");
    const CEnum = @import("c_enum.zig").parent.make().?.child;
};

// Runtime initializers must keep their dependency order when applying fixes.
pub fn local_call_dependency() void {
    const z = @import("factory.zig").make();
    const a = @import("factory.zig").consume(z);
    _ = a;
}
