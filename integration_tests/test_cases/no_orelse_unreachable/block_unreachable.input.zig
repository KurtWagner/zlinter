var optional: ?u32 = null;

const a = optional orelse {
    unreachable;
};
