const LspNotification = @This();

// zlinter-disable field_naming - we dont control the naming of methods
pub const Method = enum {
    initialized,
    /// Forceful shutdown
    exit,
    @"textDocument/didOpen",
    @"textDocument/didChange",
    @"textDocument/didSave",
    @"textDocument/didClose",
};
// zlinter-enable field_naming

// zlinter-disable field_naming - we dont control the naming of methods
const MethodParams = union(enum) {
    initialized: InitializedParams,
    exit: ExitParams,
    @"textDocument/didOpen": TextDocumentDidOpenParams,
    @"textDocument/didChange": TextDocumentDidChangeParams,
    @"textDocument/didSave": TextDocumentDidSaveParams,
    @"textDocument/didClose": TextDocumentDidCloseParams,
};
// zlinter-enable field_naming

const TextDocumentDidOpenParams = struct {
    text_document: TextDocument,
};
const TextDocumentDidChangeParams = struct {
    text_document: TextDocument,
};
const TextDocumentDidSaveParams = struct {
    text_document: TextDocument,
};
const TextDocumentDidCloseParams = struct {
    text_document: TextDocument,
};

// zlinter-disable declaration_naming
const ExitParams = struct {};
const InitializedParams = struct {};
// zlinter-enable declaration_naming

const TextDocument = struct {
    uri: std.Uri,
    version: ?i32 = null,
};

const RawTextDocument = struct {
    uri: []const u8,
    version: ?i32 = null,
};

method_params: MethodParams,

pub fn jsonParse(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !LspNotification {
    if (.object_begin != try source.next()) return error.UnexpectedToken;

    var method: ?Method = null;
    var params_value: ?std.json.Value = null;
    var text_document: ?TextDocument = null;

    tokens: while (true) {
        const token = try source.nextAlloc(allocator, options.allocate.?);
        switch (token) {
            inline .string, .allocated_string => |key| {
                if (std.mem.eql(u8, key, "method")) {
                    const raw_method = switch (try source.nextAlloc(allocator, options.allocate.?)) {
                        inline .string, .allocated_string => |value| value,
                        else => return error.UnexpectedToken,
                    };
                    method = std.meta.stringToEnum(Method, raw_method) orelse
                        return error.InvalidEnumTag;
                } else if (std.mem.eql(u8, key, "params"))
                    params_value = try std.json.innerParse(
                        std.json.Value,
                        allocator,
                        source,
                        options,
                    )
                else
                    _ = try std.json.innerParse(
                        std.json.Value,
                        allocator,
                        source,
                        options,
                    );
            },
            .object_end => break :tokens,
            else => return error.UnexpectedToken,
        }
    }

    if (params_value) |params| {
        if (params != .object) return error.UnexpectedToken;
        if (params.object.get("textDocument")) |raw_text_document| {
            const parsed_text_document = std.json.parseFromValueLeaky(
                RawTextDocument,
                allocator,
                raw_text_document,
                .{ .ignore_unknown_fields = true },
            ) catch return error.UnexpectedToken;
            text_document = .{
                .uri = std.Uri.parse(parsed_text_document.uri) catch
                    return error.UnexpectedToken,
                .version = parsed_text_document.version,
            };
        }
    }

    const params: MethodParams = switch (method orelse return error.MissingField) {
        .initialized => .initialized,
        .exit => .exit,
        .@"textDocument/didOpen" => .{
            .@"textDocument/didOpen" = .{
                .text_document = text_document orelse
                    return error.MissingField,
            },
        },
        .@"textDocument/didChange" => .{
            .@"textDocument/didChange" = .{
                .text_document = text_document orelse
                    return error.MissingField,
            },
        },
        .@"textDocument/didSave" => .{
            .@"textDocument/didSave" = .{
                .text_document = text_document orelse
                    return error.MissingField,
            },
        },
        .@"textDocument/didClose" => .{
            .@"textDocument/didClose" = .{
                .text_document = text_document orelse
                    return error.MissingField,
            },
        },
    };

    return .{ .method_params = params };
}

test {
    std.testing.refAllDecls(@This());
}

test "parses textDocument/didOpen notification from raw JSON" {
    const notification = try parseForTest(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "textDocument/didOpen",
        \\  "params": {
        \\    "textDocument": {
        \\      "uri": "file:///tmp/did-open.zig",
        \\      "languageId": "zig",
        \\      "version": 1,
        \\      "text": "const x = 1;\n"
        \\    }
        \\  }
        \\}
    );
    defer notification.deinit();

    const expected: MethodParams = .{
        .@"textDocument/didOpen" = .{
            .text_document = .{
                .uri = try std.Uri.parse("file:///tmp/did-open.zig"),
                .version = 1,
            },
        },
    };
    try std.testing.expectEqualDeep(
        expected,
        notification.value.method_params,
    );
}

test "parses textDocument/didChange notification from raw JSON" {
    const notification = try parseForTest(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "textDocument/didChange",
        \\  "params": {
        \\    "textDocument": {
        \\      "uri": "file:///tmp/did-change.zig",
        \\      "version": 2
        \\    },
        \\    "contentChanges": [
        \\      {
        \\        "text": "const x = 2;\n"
        \\      }
        \\    ]
        \\  }
        \\}
    );
    defer notification.deinit();

    const expected: MethodParams = .{
        .@"textDocument/didChange" = .{
            .text_document = .{
                .uri = try std.Uri.parse("file:///tmp/did-change.zig"),
                .version = 2,
            },
        },
    };
    try std.testing.expectEqualDeep(
        expected,
        notification.value.method_params,
    );
}

test "parses textDocument/didSave notification from raw JSON" {
    const notification = try parseForTest(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "textDocument/didSave",
        \\  "params": {
        \\    "textDocument": {
        \\      "uri": "file:///tmp/did-save.zig"
        \\    },
        \\    "text": "const x = 3;\n"
        \\  }
        \\}
    );
    defer notification.deinit();

    const expected: MethodParams = .{
        .@"textDocument/didSave" = .{
            .text_document = .{
                .uri = try std.Uri.parse("file:///tmp/did-save.zig"),
                .version = null,
            },
        },
    };
    try std.testing.expectEqualDeep(
        expected,
        notification.value.method_params,
    );
}

test "parses textDocument/didClose notification from raw JSON" {
    const notification = try parseForTest(
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "textDocument/didClose",
        \\  "params": {
        \\    "textDocument": {
        \\      "uri": "file:///tmp/did-close.zig"
        \\    }
        \\  }
        \\}
    );
    defer notification.deinit();

    const expected: MethodParams = .{
        .@"textDocument/didClose" = .{
            .text_document = .{
                .uri = try std.Uri.parse("file:///tmp/did-close.zig"),
                .version = null,
            },
        },
    };
    try std.testing.expectEqualDeep(
        expected,
        notification.value.method_params,
    );
}

fn parseForTest(json: []const u8) !std.json.Parsed(LspNotification) {
    return std.json.parseFromSlice(
        LspNotification,
        std.testing.allocator,
        json,
        .{},
    );
}

const std = @import("std");
