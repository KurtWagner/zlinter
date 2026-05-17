export fn exportedTooMany(a: u32, b: u32, c: u32) void;
extern fn externTooMany(a: u32, b: u32, c: u32) void;

pub fn normalTooMany(a: u32, b: u32, c: u32) void {
    _ = .{ a, b, c };
}
