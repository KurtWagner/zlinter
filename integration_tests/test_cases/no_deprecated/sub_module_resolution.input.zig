const sub_module = @import("sub_module");
const direct_module_a = @import("../../sub_module_a_src/root.zig");
const direct_module_b = @import("../../sub_module_b_src/root.zig");

pub fn lengthOfName(name: []const u8) u32 {
    return sub_module.strLen(name);
}

pub fn lengthOfNameA(name: []const u8) u32 {
    return direct_module_a.strLen(name);
}

pub fn lengthOfNameB(name: []const u8) u32 {
    return direct_module_b.strLen(name);
}
