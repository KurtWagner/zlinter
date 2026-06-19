var global_counter: u32 = 0;

const GlobalState = struct {
    var instance: GlobalState = .{};

    const Nested = struct {
        var active: bool = false;
    };

    local: u8 = 0,
};

fn localState() void {
    var local_counter: u32 = 0;
    local_counter += 1;
}
