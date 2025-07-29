const system = struct {
    const FAILURE: u32 = 1; // zlinter-disable-current-line
    const nested = struct {
        const Uint: u32 = 10; // zlinter-disable-current-line
    };
};

const FAILURE = system.FAILURE;
pub const Uint = system.nested.Uint;
const NOT_ALIAS = system.FAILURE;
