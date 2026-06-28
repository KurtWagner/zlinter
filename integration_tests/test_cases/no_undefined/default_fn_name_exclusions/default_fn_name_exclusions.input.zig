fn deinit() void {
    var skipped: u32 = undefined;
    _ = skipped;
}

fn notDeinit() void {
    var should_warn: u32 = undefined;
    _ = should_warn;
}

fn my_deinit_helper() void {
    var also_warn: u32 = undefined;
    _ = also_warn;
}
