const LspError = struct {
    code: JsonRpcErrorCode,
    /// Optional id from the request to include in the response
    id: ?std.json.Value = null,
    /// Optional explicit message otherwise will default to a name for the code
    message: ?[]const u8 = null,
};

const JsonRpcErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

const LspState = enum {
    running,
    stopping,
};

// zlinter-disable field_naming - we dont control the naming of methods
const LspRequestMethod = enum {
    initialize,
    /// Polite shutdown request
    shutdown,
};
// zlinter-enable field_naming

// zlinter-disable field_naming - we dont control the naming of methods
const LspNotificationMethod = enum {
    initialized,
    /// Forceful shutdown
    exit,
    @"textDocument/didOpen",
    @"textDocument/didChange",
    @"textDocument/didSave",
    @"textDocument/didClose",
};
// zlinter-enable field_naming

pub const LspServer = struct {
    gpa: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,

    /// Arena that lives the duration of every message being handled.
    handle_arena: std.heap.ArenaAllocator,

    pub fn init(
        gpa: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
    ) LspServer {
        return .{
            .gpa = gpa,
            .reader = reader,
            .writer = writer,
            .handle_arena = .init(gpa),
        };
    }

    pub fn run(self: *LspServer) error{ WriteFailed, LspError, OutOfMemory }!void {
        // TODO: Add some keep alive / tll logic?

        defer _ = self.handle_arena.reset(.free_all);

        var err: LspError = undefined;
        var state: LspState = .running;
        reading: while (state == .running) {
            defer _ = self.handle_arena.reset(.retain_capacity);

            const body = self.readMessage(
                self.handle_arena.allocator(),
                &err,
            ) catch |e| {
                try self.sendError(err);
                switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LspError => continue :reading,
                }
            } orelse {
                state = .stopping;
                continue :reading;
            };

            state = self.handleMessage(
                body,
                &err,
            ) catch |e| {
                try self.sendError(err);
                switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.LspError => continue :reading,
                }
            };
        }
    }

    fn readMessage(
        self: *LspServer,
        arena: std.mem.Allocator,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!?[]u8 {
        var content_length: ?u32 = null;
        while (true) {
            const raw_line = self.reader.takeDelimiterInclusive('\n') catch |e| {
                switch (e) {
                    // TODO: Separate LspInternalError from LspUsageError
                    error.EndOfStream => return null,
                    error.ReadFailed => {}, // TODO: Internal error
                    error.StreamTooLong => {}, // TODO: Usage error
                }
                err.* = .{
                    .code = JsonRpcErrorCode.invalid_request,
                    .message = self.tryDupe("Failed to read headers"),
                };
                return error.LspError;
            };

            const line = std.mem.trimEnd(u8, raw_line, "\r\n");
            if (line.len == 0) break;

            // TODO: Should we read until ":" then get trimmed key. e.g., "Content-Length :"
            const content_len_key = "Content-Length:";
            if (std.ascii.startsWithIgnoreCase(line, content_len_key)) {
                const value = std.mem.trim(
                    u8,
                    line[content_len_key.len..],
                    &std.ascii.whitespace,
                );
                content_length = std.fmt.parseInt(u32, value, 10) catch {
                    err.* = .{
                        .code = JsonRpcErrorCode.invalid_request,
                        .message = self.tryDupe("Failed to parse content length"),
                    };
                    return error.LspError;
                };
            }
        }

        const len = content_length orelse {
            err.* = .{
                .code = JsonRpcErrorCode.invalid_request,
                .message = self.tryDupe("Missing content length header"),
            };
            return error.LspError;
        };
        const body = arena.alloc(u8, len) catch {
            err.* = .{
                .code = JsonRpcErrorCode.internal_error,
                .message = self.tryDupe("Out of memory"),
            };
            return error.OutOfMemory;
        };

        self.reader.readSliceAll(body) catch |e| {
            switch (e) {
                error.EndOfStream => err.* = .{
                    .code = JsonRpcErrorCode.invalid_request,
                    .message = self.tryDupe("Body was incomplete"),
                },
                error.ReadFailed => err.* = .{
                    .code = JsonRpcErrorCode.internal_error,
                    .message = self.tryDupe("Failed to ready the body"),
                },
            }
            return error.LspError;
        };

        return body;
    }

    fn handleMessage(
        self: *LspServer,
        body: []const u8,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!LspState {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.handle_arena.allocator(),
            body,
            .{},
        ) catch {
            std.log.err("Json: '{s}'", .{body});
            err.* = .{
                .code = JsonRpcErrorCode.parse_error,
                .message = self.tryDupe("Invalid JSON"),
            };
            return error.LspError;
        };

        const message = parsed.value;
        const method_str = try self.readMethodFromMessage(
            message,
            err,
        );

        if (std.meta.stringToEnum(
            LspRequestMethod,
            method_str,
        )) |method| {
            // Is a request, expect id to respond with:
            const id = try self.readIdFromMessage(
                message,
                err,
            );
            return try self.handleRequest(
                id,
                method,
                message,
                err,
            );
        } else if (std.meta.stringToEnum(
            LspNotificationMethod,
            method_str,
        )) |method| {
            // Is notification, no id, no response to send:
            return try self.handleNotification(method, message, err);
        } else if (message.object.get("id")) |id| {
            // Assume request when there's an id so we need to respond with error:
            err.* = .{
                .code = .method_not_found,
                .id = id,
                .message = self.tryDupe("zlinter does not handle that method"),
            };
            return error.LspError;
        }
        // else assume notification that we don't handle, ignore.
        return .running;
    }

    fn readMethodFromMessage(
        self: *LspServer,
        message: std.json.Value,
        err: *LspError,
    ) error{LspError}![]const u8 {
        const method_value = message.object.get("method") orelse {
            err.* = .{
                .code = JsonRpcErrorCode.invalid_params,
                .message = self.tryDupe("Missing 'method' parameter"),
            };
            return error.LspError;
        };

        return switch (method_value) {
            .string => |str| str,
            else => {
                err.* = .{
                    .code = JsonRpcErrorCode.invalid_params,
                    .message = self.tryDupe("Expected 'method' to be a string"),
                };
                return error.LspError;
            },
        };
    }

    fn readIdFromMessage(
        self: *LspServer,
        message: std.json.Value,
        err: *LspError,
    ) error{LspError}!std.json.Value {
        return message.object.get("id") orelse {
            err.* = .{
                .code = JsonRpcErrorCode.invalid_params,
                .message = self.tryDupe("Missing 'id' parameter"),
            };
            return error.LspError;
        };
    }

    fn handleRequest(
        self: *LspServer,
        id: std.json.Value,
        method: LspRequestMethod,
        message: std.json.Value,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!LspState {
        _ = message;

        switch (method) {
            .initialize => try self.sendInitializeResponse(id, err),
            .shutdown => {
                try self.sendResponse(id, .null, err);
                return .stopping;
            },
        }
        return .running;
    }

    fn handleNotification(
        self: *LspServer,
        method: LspNotificationMethod,
        message: std.json.Value,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!LspState {
        switch (method) {
            .initialized => {},
            .exit => return .stopping,
            .@"textDocument/didOpen" =>
            // TODO:
            // - params.textDocument.uri or params.textDocument.text?
            // - run linter on text
            try self.publishEmptyDiagnostics(message, err),
            .@"textDocument/didClose" => {},
            .@"textDocument/didChange" =>
            // TODO:
            // - maintain uri to file id in file store
            // - rerun linter
            try self.publishEmptyDiagnostics(message, err),
            .@"textDocument/didSave" =>
            // TODO:
            // - rerun linter
            try self.publishEmptyDiagnostics(message, err),
        }
        return .running;
    }

    fn sendInitializeResponse(
        self: *LspServer,
        id: std.json.Value,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!void {
        // change = 1 = full (not incremental)
        const arena = self.handle_arena.allocator();

        var text_document_sync: std.json.ObjectMap = .empty;
        try text_document_sync.put(arena, "openClose", .{ .bool = true });
        try text_document_sync.put(arena, "change", .{ .integer = 1 });
        try text_document_sync.put(arena, "save", .{ .bool = true });

        var capabilities: std.json.ObjectMap = .empty;
        try capabilities.put(arena, "textDocumentSync", .{ .object = text_document_sync });
        try capabilities.put(arena, "codeActionProvider", .{ .bool = false });

        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(arena, "name", .{ .string = "zlinter" });
        // TODO: Put zlinter version in the server info...
        try server_info.put(arena, "version", .{ .string = "0.0.0" });

        var result_obj: std.json.ObjectMap = .empty;
        try result_obj.put(arena, "capabilities", .{ .object = capabilities });
        try result_obj.put(arena, "serverInfo", .{ .object = server_info });

        const result: std.json.Value = .{ .object = result_obj };

        try self.sendResponse(id, result, err);
    }

    fn publishEmptyDiagnostics(
        self: *LspServer,
        msg: std.json.Value,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!void {
        const params = msg.object.get("params") orelse return;

        const text_document =
            params.object.get("textDocument") orelse
            params.object.get("document") orelse
            return;

        const uri = text_document.object.get("uri") orelse return;

        var body: std.Io.Writer.Allocating = .init(self.handle_arena.allocator());
        body.writer.print(
            \\{{"jsonrpc":"2.0","method":"textDocument/publishDiagnostics","params":{{"uri":{},"diagnostics":[]}}}}
        ,
            .{std.json.fmt(uri, .{})},
        ) catch |e| switch (e) {
            error.WriteFailed => {
                err.* = .{
                    .code = .internal_error,
                    .message = self.tryDupe("Failed to write body likely OOM"),
                };
                return error.OutOfMemory;
            },
        };
        try self.writeMessage(body.written(), err);
    }

    fn sendResponse(
        self: *LspServer,
        id: std.json.Value,
        result: std.json.Value,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!void {
        const arena = self.handle_arena.allocator();

        var root_json_obj: std.json.ObjectMap = .empty;
        try root_json_obj.put(
            arena,
            "jsonrpc",
            .{ .string = "2.0" },
        );
        try root_json_obj.put(
            arena,
            "id",
            id,
        );

        try root_json_obj.put(
            arena,
            "result",
            result,
        );

        const body = try std.json.Stringify.valueAlloc(
            arena,
            std.json.Value{
                .object = root_json_obj,
            },
            .{},
        );
        if (builtin.is_test)
            std.log.info("LSP Error: {s}", .{body});

        try self.writeMessage(body, err);
    }

    fn sendError(
        self: *LspServer,
        err: LspError,
    ) error{ WriteFailed, LspError, OutOfMemory }!void {
        const arena = self.handle_arena.allocator();

        var root_json_obj: std.json.ObjectMap = .empty;
        try root_json_obj.put(
            arena,
            "jsonrpc",
            .{ .string = "2.0" },
        );
        if (err.id) |id| {
            try root_json_obj.put(
                arena,
                "id",
                id,
            );
        }

        var err_json_obj: std.json.ObjectMap = .empty;
        try err_json_obj.put(
            arena,
            "code",
            .{ .integer = @intFromEnum(err.code) },
        );
        try err_json_obj.put(
            arena,
            "message",
            .{
                .string = err.message orelse switch (err.code) {
                    .parse_error => "Parse error",
                    .invalid_request => "Invalid request",
                    .method_not_found => "Method not found",
                    .invalid_params => "Invalid params",
                    .internal_error => "Internal error",
                },
            },
        );
        try root_json_obj.put(
            arena,
            "error",
            .{
                .object = err_json_obj,
            },
        );

        const body = try std.json.Stringify.valueAlloc(
            arena,
            std.json.Value{
                .object = root_json_obj,
            },
            .{},
        );
        if (builtin.is_test)
            std.log.info("LSP Error: {s}", .{body});

        try self.writeMessage(body, null);
    }

    fn writeMessage(self: *LspServer, body: []const u8, err: ?*LspError) error{ LspError, OutOfMemory }!void {
        self.writer.print(
            "Content-Length: {}\r\n\r\n{s}",
            .{ body.len, body },
        ) catch |e| switch (e) {
            error.WriteFailed => {
                if (err != null)
                    err.?.* = .{
                        .code = .internal_error,
                        .message = self.tryDupe("Failed to write body, assuming OOM"),
                    };
                return error.OutOfMemory;
            },
        };

        self.writer.flush() catch |e| switch (e) {
            error.WriteFailed => {
                if (err != null)
                    err.?.* = .{
                        .code = .internal_error,
                        .message = self.tryDupe("Failed to flush body, assuming OOM"),
                    };
                return error.OutOfMemory;
            },
        };
    }

    fn tryDupe(self: *LspServer, input: []const u8) ?[]const u8 {
        return self.handle_arena.allocator().dupe(u8, input) catch null;
    }
};

test {
    var stdin: std.Io.Reader = .fixed(comptime testBody(
        \\{"method":"initialize", "id":1}
    ) ++ testBody(
        \\{"method":"shutdown", "id":2}
    ));
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    var server: LspServer = .init(
        std.testing.allocator,
        &stdin,
        &stdout.writer,
    );
    try server.run();

    try std.testing.expectEqualStrings(comptime testBody(
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"textDocumentSync":{"openClose":true,"change":1,"save":true},"codeActionProvider":false},"serverInfo":{"name":"zlinter","version":"0.0.0"}}}
    ) ++ testBody(
        \\{"jsonrpc":"2.0","id":2,"result":null}
    ), stdout.written());
}

fn testBody(comptime body: []const u8) []const u8 {
    if (!builtin.is_test) @compileError("test only");
    return std.fmt.comptimePrint(
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const builtin = @import("builtin");
