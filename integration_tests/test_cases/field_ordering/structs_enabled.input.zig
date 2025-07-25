const Packed = packed struct(u64) {
    a: u32,
    c: u32,
};

const Extern = extern struct {
    a: u32,
    c: u32,
};

const Normal = struct {
    a: u32,
    c: u32,
};
