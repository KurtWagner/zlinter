pub const name = "jack";

const age = 32;

pub fn getName() []const u8 {
    return name;
}

fn getAge() u32 {
    return age;
}
