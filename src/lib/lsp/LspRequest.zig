const LspRequest = @This();

// zlinter-disable field_naming - we dont control the naming of methods
pub const Method = enum {
    /// Set when we get a method we dont support.
    unsupported,
    initialize,
    /// Polite shutdown request
    shutdown,
};
// zlinter-enable field_naming

pub const Id = union(enum) {
    integer: i64,
    string: []const u8,
};

// zlinter-disable field_naming - we dont control the naming of methods
const MethodParams = union(enum) {
    unknown: void,
    initialize: void,
    shutdown: void,
};
// zlinter-enable field_naming

id: Id,
method_params: MethodParams,

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !LspRequest {
    if (.object_begin != try source.next()) return error.UnexpectedToken;

    var method: ?Method = null;
    var id: ?Id = null;

    tokens: while (true) {
        const token = try source.nextAlloc(allocator, options.allocate.?);
        switch (token) {
            inline .string, .allocated_string => |key| {
                if (std.mem.eql(u8, key, "id")) {
                    id = switch (try source.nextAlloc(allocator, options.allocate.?)) {
                        .number => |value| .{
                            .integer = std.fmt.parseInt(i64, value, 10) catch
                                return error.UnexpectedToken,
                        },
                        inline .string, .allocated_string => |value| .{
                            .string = value,
                        },
                        else => return error.UnexpectedToken,
                    };
                } else if (std.mem.eql(u8, key, "method")) {
                    const raw_method = switch (try source.nextAlloc(
                        allocator,
                        options.allocate.?,
                    )) {
                        inline .string, .allocated_string => |value| value,
                        else => return error.UnexpectedToken,
                    };
                    method = std.meta.stringToEnum(Method, raw_method) orelse
                        return error.InvalidEnumTag;
                } else {
                    _ = try std.json.innerParse(
                        std.json.Value,
                        allocator,
                        source,
                        options,
                    );
                }
            },
            .object_end => break :tokens,
            else => return error.UnexpectedToken,
        }
    }

    const params: MethodParams = switch (method orelse .unsupported) {
        .initialize => .initialize,
        .shutdown => .shutdown,
        .unsupported => .unknown,
    };

    return .{
        .id = id orelse return error.MissingField,
        .method_params = params,
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "parses initialize request from raw JSON" {
    const request = try parseForTest(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": 1,
        \\  "method": "initialize",
        \\  "params": {
        \\    "processId": 123
        \\  }
        \\}
    );
    defer request.deinit();

    const expected: MethodParams = .initialize;
    try std.testing.expectEqualDeep(expected, request.value.method_params);
    try std.testing.expectEqualDeep(Id{ .integer = 1 }, request.value.id);
}

test "parses shutdown request from raw JSON" {
    const request = try parseForTest(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "id": "shutdown-2",
        \\  "method": "shutdown"
        \\}
    );
    defer request.deinit();

    const expected: MethodParams = .shutdown;
    try std.testing.expectEqualDeep(expected, request.value.method_params);
    try std.testing.expectEqualDeep(Id{ .string = "shutdown-2" }, request.value.id);
}

fn parseForTest(json: []const u8) !std.json.Parsed(LspRequest) {
    return std.json.parseFromSlice(
        LspRequest,
        std.testing.allocator,
        json,
        .{},
    );
}

const std = @import("std");
