const State = enum { none, ready, unspecified };
const Payload = union(enum) { none, text: []const u8 };

fn returnsUndefined() ?u32 {
    return undefined;
}

fn breaksUndefined() State {
    return blk: {
        break :blk undefined;
    };
}

const maybe_value: ?u32 = undefined;
const state: State = undefined;
const payload: Payload = undefined;
const ptr: *u32 = undefined;
const inferred = undefined;

var buffer: [1024]u8 = undefined;
var number: u32 = undefined;
const ok_maybe: ?u32 = null;
const ok_state: State = .none;
const ok_payload: Payload = .none;
const ok_ptr: ?*u32 = null;
