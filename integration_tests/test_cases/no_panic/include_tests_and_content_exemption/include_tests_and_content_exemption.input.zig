pub fn panic_oom() void {
    @panic("OOM");
}

pub fn panic_o_x4f_m() void {
    @panic("O\x4fM");
}

pub fn panic_empty() void {
    @panic("");
}

pub fn panic_escaped_quote() void {
    @panic("a\"b");
}

pub fn panic_other() void {
    @panic("other");
}

test {
    @panic("test fail");
}
