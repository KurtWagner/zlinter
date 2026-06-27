var optional: ?u32 = null;

const a = optional orelse 10;
const b = optional orelse unreachable;
const c = optional.?;
