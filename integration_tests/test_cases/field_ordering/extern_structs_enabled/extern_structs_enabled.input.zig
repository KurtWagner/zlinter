const Packed = packed struct(u64) {
    b: u32,
    a: u32,
};

const Extern = extern struct {
    b: u32,
    a: u32,
};

const Normal = struct {
    b: u32,
    a: u32,
};
