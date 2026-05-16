const Self = @This();
const bad_type = @This();

const RunResult = enum {
    success,
    tool_error,
};

fn sample() void {
    const run_result: RunResult = .success;
    var badResult: RunResult = .tool_error;
    _ = run_result;
    _ = &badResult;
}
