const sub_module = @import("sub_module");

pub fn handle(value: sub_module.Type) void {
    switch (value) {
        .a => {},
        else => {},
    }
}
