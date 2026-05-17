pub fn main() void {
    @panic("OOM");
    @panic("other");
}

test {
    @panic("OOM");
    @panic("test fail");
}
