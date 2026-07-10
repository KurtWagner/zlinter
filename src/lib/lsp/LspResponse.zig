const LspResponse = @This();

payload: Payload,

pub const JsonRpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

pub const ErrorPayload = struct {
    id: ?LspRequest.Id = null,
    code: JsonRpcErrorCode,
    message: []const u8,
};

const Payload = union(enum) {
    notification: MethodParams,
    result: Result,
    @"error": ErrorPayload,
};

pub const Result = struct {
    id: LspRequest.Id,
    value: ResultValue,
};

const ResultValue = union(enum) {
    initialize: InitializeResult,
    shutdown: void,
};

// zlinter-disable field_naming - we don't control the method names
const Method = enum {
    @"textDocument/publishDiagnostics",
};
// zlinter-enable field_naming

// zlinter-disable field_naming - we don't control the method names
const MethodParams = union(Method) {
    @"textDocument/publishDiagnostics": PublishDiagnosticsParams,
};
// zlinter-enable field_naming

const PublishDiagnosticsParams = struct {
    uri: std.Uri,
    diagnostics: []const LspDiagnostic,

    pub fn jsonStringify(self: @This(), jws: anytype) !void {
        try jws.beginObject();

        try jws.objectField("uri");
        try jsonStringifyUri(self.uri, jws);

        try jws.objectField("diagnostics");
        try jws.write(self.diagnostics);

        try jws.endObject();
    }
};

const InitializeResult = struct {
    capabilities: Capabilities,
    serverInfo: ServerInfo,
};

const Capabilities = struct {
    textDocumentSync: TextDocumentSync,
    codeActionProvider: bool,
};

const TextDocumentSync = struct {
    openClose: bool,
    change: u8,
    save: bool,
};

const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Diagnostic (lint result) returned by LSP
pub const LspDiagnostic = struct {
    const Position = struct {
        line: u32,
        character: u32,
    };

    const Range = struct {
        start: Position,
        end: Position,
    };

    const Severity = enum(u8) {
        @"error" = 1,
        warning = 2,
        information = 3,
        hint = 4,
    };

    /// Always set to "zlinter", just set on object to simplify json stringifying
    source: []const u8 = "zlinter",

    /// The rule id. e.g., `require_braces`
    code: []const u8,

    /// e.g., field `a` is deprecated, use `b` instead
    message: []const u8,

    /// Where the problem exists in the file
    range: Range,

    /// The severity of the diagnostic that's highlighted
    severity: Severity,

    pub fn initFromProblem(
        problem: LintProblem,
        file_store: *const FileStore,
        file_id: FileId,
        arena: std.mem.Allocator,
    ) LspDiagnostic {
        const range = file_store.fileRange(
            file_id,
            problem.start.byte_offset,
            problem.end.byte_offset,
        );

        return .{
            .code = arena.dupe(u8, problem.rule_id) catch @panic("OOM"),
            .message = arena.dupe(u8, problem.message) catch @panic("OOM"),
            .severity = switch (problem.severity) {
                .off => unreachable,
                .warning => .warning,
                .@"error" => .@"error",
            },
            .range = .{
                .start = .{
                    .line = @intCast(range.start.line),
                    .character = @intCast(range.start.column),
                },
                .end = .{
                    .line = @intCast(range.end.line),
                    .character = @intCast(range.end.column),
                },
            },
        };
    }
};

// zlinter-disable-next-line no_inferred_error_unions - not even sure what the errors are.
pub fn jsonStringify(self: @This(), jws: anytype) !void {
    try jws.beginObject();

    try jws.objectField("jsonrpc");
    try jws.write("2.0");

    switch (self.payload) {
        .notification => |method_params| {
            try jws.objectField("method");
            try jws.write(@tagName(std.meta.activeTag(method_params)));

            try jws.objectField("params");
            switch (method_params) {
                inline else => |payload| try jws.write(payload),
            }
        },
        .result => |result| {
            try jws.objectField("id");
            try jsonStringifyId(result.id, jws);

            try jws.objectField("result");
            switch (result.value) {
                .initialize => |value| try jws.write(value),
                .shutdown => try jws.write(null),
            }
        },
        .@"error" => |error_payload| {
            if (error_payload.id) |id| {
                try jws.objectField("id");
                try jsonStringifyId(id, jws);
            }

            try jws.objectField("error");
            try jws.beginObject();

            try jws.objectField("code");
            try jws.write(@intFromEnum(error_payload.code));

            try jws.objectField("message");
            try jws.write(error_payload.message);

            try jws.endObject();
        },
    }

    try jws.endObject();
}

fn jsonStringifyId(id: LspRequest.Id, jws: anytype) !void {
    switch (id) {
        .integer => |value| try jws.write(value),
        .string => |value| try jws.write(value),
    }
}

fn jsonStringifyUri(uri: std.Uri, jws: anytype) !void {
    try jws.beginWriteRaw();
    defer jws.endWriteRaw();

    try jws.writer.writeByte('"');
    if (std.mem.eql(u8, uri.scheme, "file") and uri.host == null) {
        try jws.writer.print("{s}://", .{uri.scheme});

        const uri_path: std.Uri.Component = if (uri.path.isEmpty())
            .{ .percent_encoded = "/" }
        else
            uri.path;
        try uri_path.formatPath(jws.writer);

        if (uri.query) |query| {
            try jws.writer.writeByte('?');
            try query.formatQuery(jws.writer);
        }
        if (uri.fragment) |fragment| {
            try jws.writer.writeByte('#');
            try fragment.formatFragment(jws.writer);
        }
    } else {
        try std.Uri.writeToStream(&uri, jws.writer, .all);
    }
    try jws.writer.writeByte('"');
}

test "textDocument/publishDiagnostics json" {
    const response: LspResponse = .{
        .payload = .{
            .notification = .{
                .@"textDocument/publishDiagnostics" = .{
                    .uri = try std.Uri.parse("file://fake/file.zig"),
                    .diagnostics = &.{
                        .{
                            .range = .{
                                .start = .{
                                    .line = 1,
                                    .character = 3,
                                },
                                .end = .{
                                    .line = 2,
                                    .character = 4,
                                },
                            },
                            .severity = .warning,
                            .code = "no_deprecated",
                            .message = "field `a` is deprecated, use `b` instead",
                        },
                    },
                },
            },
        },
    };

    const actual = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        response,
        .{
            .whitespace = .indent_2,
        },
    );
    defer std.testing.allocator.free(actual);

    const expected =
        \\{
        \\  "jsonrpc": "2.0",
        \\  "method": "textDocument/publishDiagnostics",
        \\  "params": {
        \\    "uri": "file://fake/file.zig",
        \\    "diagnostics": [
        \\      {
        \\        "range": {
        \\          "start": {
        \\            "line": 1,
        \\            "character": 3
        \\          },
        \\          "end": {
        \\            "line": 2,
        \\            "character": 4
        \\          }
        \\        },
        \\        "severity": "warning",
        \\        "code": "no_deprecated",
        \\        "source": "zlinter",
        \\        "message": "field `a` is deprecated, use `b` instead"
        \\      }
        \\    ]
        \\  }
        \\}
    ;

    testing.expectJsonEqual(
        expected,
        actual,
    ) catch |e| {
        std.debug.print("Actual:\n", .{});
        var lines = std.mem.splitScalar(u8, actual, '\n');
        while (lines.next()) |line|
            std.debug.print("\\\\{s}\n", .{line});
        return e;
    };
}

test "initialize response json" {
    const response: LspResponse = .{
        .payload = .{
            .result = .{
                .id = .{ .integer = 1 },
                .value = .{
                    .initialize = .{
                        .capabilities = .{
                            .textDocumentSync = .{
                                .openClose = true,
                                .change = 1,
                                .save = true,
                            },
                            .codeActionProvider = false,
                        },
                        .serverInfo = .{
                            .name = "zlinter",
                            .version = "0.0.0",
                        },
                    },
                },
            },
        },
    };

    const actual = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        response,
        .{},
    );
    defer std.testing.allocator.free(actual);
    const expected =
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":true},"codeActionProvider":false},"serverInfo":{"name":"zlinter","version":"0.0.0"}}}
    ;

    try testing.expectJsonEqual(
        expected,
        actual,
    );
}

test "error response json" {
    const response: LspResponse = .{
        .payload = .{
            .@"error" = .{
                .id = .{ .string = "bad-request" },
                .code = .invalid_request,
                .message = "Invalid request",
            },
        },
    };

    const actual = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        response,
        .{},
    );
    defer std.testing.allocator.free(actual);
    const expected =
        \\{"jsonrpc":"2.0","id":"bad-request","error":{"code":-32600,"message":"Invalid request"}}
    ;

    try testing.expectJsonEqual(
        expected,
        actual,
    );
}

test {
    std.testing.refAllDecls(@This());
}

const testing = @import("../testing.zig");
const std = @import("std");
const FileId = @import("../session/FileStore.zig").FileId;
const FileStore = @import("../session/FileStore.zig");
const LintProblem = @import("../results.zig").LintProblem;
const LspRequest = @import("LspRequest.zig");
