const MyStruct = struct {
    fn boot(self: *@This()) void {
        _ = self;
    }
};

fn cleanupNow() void {
    var should_skip: u32 = undefined;
    _ = should_skip;
}

pub fn main() void {
    var special_skip: u32 = undefined;
    _ = special_skip;

    var x_scratch: u32 = undefined;
    _ = x_scratch;

    var booted: MyStruct = undefined;
    booted.boot();

    var still_bad: u32 = undefined;
    _ = still_bad;
}
