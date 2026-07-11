const LspError = struct {
    code: LspResponse.JsonRpcErrorCode,
    /// Optional id from the request to include in the response
    id: ?LspRequest.Id = null,
    /// Optional explicit message otherwise will default to a name for the code
    message: ?[]const u8 = null,
};

const LspState = enum {
    running,
    stopping,
};

pub const LspServer = struct {
    runtime: *const LintRuntime,
    session: *LintSession,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    rules: []const LintRule,
    lint_config_store: LintConfigStore,

    /// Arena that lives the duration of every message being handled.
    handle_arena: *std.heap.ArenaAllocator,

    pub fn init(
        runtime: *const LintRuntime,
        session: *LintSession,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        rules: []const LintRule,
        lint_config_store: LintConfigStore,
    ) LspServer {
        return .{
            .runtime = runtime,
            .session = session,
            .reader = reader,
            .writer = writer,
            .handle_arena = runtime.file_arena,
            .rules = rules,
            .lint_config_store = lint_config_store,
        };
    }

    pub fn run(self: *LspServer) error{ WriteFailed, LspError, OutOfMemory }!void {
        // TODO: Add some keep alive / tll logic?
        defer _ = self.handle_arena.reset(.free_all);

        var err: LspError = undefined;
        var state: LspState = .running;
        reading: while (state == .running) {
            defer _ = self.handle_arena.reset(.retain_capacity);

            const body = self.readBody(
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

            state = self.handleBody(
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

    fn readBody(
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
                    .code = .invalid_request,
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
                        .code = .invalid_request,
                        .message = self.tryDupe("Failed to parse content length"),
                    };
                    return error.LspError;
                };
            }
        }

        const len = content_length orelse {
            err.* = .{
                .code = .invalid_request,
                .message = self.tryDupe("Missing content length header"),
            };
            return error.LspError;
        };
        const body = arena.alloc(u8, len) catch {
            err.* = .{
                .code = .internal_error,
                .message = self.tryDupe("Out of memory"),
            };
            return error.OutOfMemory;
        };

        self.reader.readSliceAll(body) catch |e| {
            switch (e) {
                error.EndOfStream => err.* = .{
                    .code = .invalid_request,
                    .message = self.tryDupe("Body was incomplete"),
                },
                error.ReadFailed => err.* = .{
                    .code = .internal_error,
                    .message = self.tryDupe("Failed to ready the body"),
                },
            }
            return error.LspError;
        };

        return body;
    }

    fn handleBody(
        self: *LspServer,
        body: []const u8,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!LspState {
        if (std.json.parseFromSlice(
            LspNotification,
            self.handle_arena.allocator(),
            body,
            .{},
        )) |notification| {
            return try self.handleNotification(
                notification.value,
                err,
            );
        } else |_| {
            // Ignored.
        }

        if (std.json.parseFromSlice(
            LspRequest,
            self.handle_arena.allocator(),
            body,
            .{},
        )) |request| {
            return try self.handleRequest(
                request.value,
                err,
            );
        } else |_| {
            // Ignored.
        }

        return .running;
    }

    fn handleRequest(
        self: *LspServer,
        request: LspRequest,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!LspState {
        switch (request.method_params) {
            .initialize => try self.sendInitializeResponse(request.id, err),
            .shutdown => {
                self.sendResponse(.{
                    .payload = .{
                        .result = .{
                            .id = request.id,
                            .value = .shutdown,
                        },
                    },
                }, err) catch {
                    // If we fail to acknowledge the shutdown we still want to stop.
                };
                return .stopping;
            },
            .unknown => {
                err.* = .{
                    .code = .method_not_found,
                    .id = request.id,
                    .message = self.tryDupe("zlinter does not handle that method"),
                };
                return error.LspError;
            },
        }
        return .running;
    }

    fn handleNotification(
        self: *LspServer,
        notification: LspNotification,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!LspState {
        switch (notification.method_params) {
            .initialized => {},
            .exit => return .stopping,
            .@"textDocument/didOpen" => |value| try self.publishDiagnostics(
                value.text_document.uri,
                err,
            ),
            .@"textDocument/didClose" => |value| try self.publishDiagnostics(
                value.text_document.uri,
                err,
            ),
            .@"textDocument/didChange" => |value| try self.publishDiagnostics(
                value.text_document.uri,
                err,
            ),
            .@"textDocument/didSave" => |value| try self.publishDiagnostics(
                value.text_document.uri,
                err,
            ),
        }
        return .running;
    }

    fn sendInitializeResponse(
        self: *LspServer,
        id: LspRequest.Id,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!void {
        try self.sendResponse(.{
            .payload = .{
                .result = .{
                    .id = id,
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
        }, err);
    }

    fn publishDiagnostics(
        self: *LspServer,
        uri: std.Uri,
        err: *LspError,
    ) error{ LspError, OutOfMemory }!void {
        try self.sendResponse(.{
            .payload = .{
                .notification = .{
                    .@"textDocument/publishDiagnostics" = .{
                        .uri = uri,
                        .diagnostics = self.getDiagnostics(uri),
                    },
                },
            },
        }, err);
    }

    fn getDiagnostics(
        self: *LspServer,
        uri: std.Uri,
    ) []const LspResponse.LspDiagnostic {
        var diagnostics: std.ArrayList(LspResponse.LspDiagnostic) = .empty;

        const abs_path = fileUriToAbsPath(self.handle_arena.allocator(), uri) orelse {
            std.log.err("Failed to get absolute path from URI '{f}'", .{uri.fmt(.all)});
            return diagnostics.items;
        };

        const file_id = self.session.file_store.resolve(abs_path) catch |e| {
            std.log.err("Failed to resolve file '{s}' in file store: {t}", .{ abs_path, e });
            return diagnostics.items;
        };

        var doc: LintDocument = undefined;
        self.session.initDocument(file_id, self.handle_arena.allocator(), &doc) catch |e| {
            std.log.err("Failed to init document '{s}'", .{ abs_path, e });
            return diagnostics.items;
        };

        self.lint_config_store.index(
            self.runtime.io,
            // TODO: We need to think about how we refresh this whemn files change
            self.runtime.sessionArena(),
            std.Io.Dir.path.dirname(abs_path).?,
            std.Io.Dir.cwd(),
        ) catch |e| {
            std.log.err("Invalid zlinter.zon seen in ancestors of '{s}': {t}", .{ abs_path, e });
            return diagnostics.items;
        };

        rules: for (self.rules, 0..) |rule, i| {
            const rule_idx: RuleIndex = @enumFromInt(i);

            const result = rule.run(
                rule,
                self.session,
                &doc,
                .{
                    .config = self.lint_config_store.lookup(
                        std.Io.Dir.path.dirname(abs_path).?,
                        rule_idx,
                    ),
                },
            ) catch |e| switch (e) {
                error.OutOfMemory => @panic("OOM"),
                else => {
                    std.log.err("Failed to lint '{s}' with '{s}': {t}", .{ abs_path, rule.rule_id, e });
                    continue :rules;
                },
            } orelse continue :rules;

            for (result.problems) |problem|
                diagnostics.append(
                    self.handle_arena.allocator(),
                    .initFromProblem(
                        problem,
                        &self.session.file_store,
                        file_id,
                        self.handle_arena.allocator(),
                    ),
                ) catch @panic("OOM");
        }

        return diagnostics.items;
    }

    fn sendError(
        self: *LspServer,
        err: LspError,
    ) error{ WriteFailed, LspError, OutOfMemory }!void {
        try self.sendResponse(.{
            .payload = .{
                .@"error" = .{
                    .id = err.id,
                    .code = err.code,
                    .message = err.message orelse switch (err.code) {
                        .parse_error => "Parse error",
                        .invalid_request => "Invalid request",
                        .method_not_found => "Method not found",
                        .invalid_params => "Invalid params",
                        .internal_error => "Internal error",
                    },
                },
            },
        }, null);
    }

    fn sendResponse(
        self: *LspServer,
        response: LspResponse,
        err: ?*LspError,
    ) error{ LspError, OutOfMemory }!void {
        const body = try std.json.Stringify.valueAlloc(
            self.handle_arena.allocator(),
            response,
            .{},
        );
        try self.writeMessage(body, err);
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
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var stdin: std.Io.Reader = .fixed(comptime testBody(
        \\{"method":"initialize", "id":1}
    ) ++ testBody(
        \\{"method":"shutdown", "id":2}
    ));
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    var noop_config_store: NoopLintConfigStore = .init;

    var session = testing.initFakeContext(arena.allocator(), std.testing.io);
    var server: LspServer = .init(
        session.runtime,
        &session,
        &stdin,
        &stdout.writer,
        &.{},
        noop_config_store.store(),
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

// TODO: Write some test helpers so make testing requests + responses easier to write and grok
test "didOpen publishes valid empty diagnostics json" {
    // TODO: Get this working with Windows path separators.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    try testing.writeFile(
        tmp_dir.dir,
        "did-open.zig",
        \\
        \\const x = 1;
        \\
        ,
    );

    var abs_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const abs_path = abs_path_buffer[0..try tmp_dir.dir.realPathFile(
        std.testing.io,
        "did-open.zig",
        &abs_path_buffer,
    )];
    const uri = try std.fmt.allocPrint(
        arena.allocator(),
        "file://{s}",
        .{abs_path},
    );
    const body = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"zig\",\"version\":1,\"text\":\"const x = 1;\\n\"}}}}}}",
        .{uri},
    );
    const input = try std.fmt.allocPrint(
        arena.allocator(),
        "Content-Length: {d}\r\n\r\n{s}",
        .{ body.len, body },
    );
    var stdin: std.Io.Reader = .fixed(input);
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();

    var noop_config_store: NoopLintConfigStore = .init;

    var session = testing.initFakeContext(arena.allocator(), std.testing.io);
    var server: LspServer = .init(
        session.runtime,
        &session,
        &stdin,
        &stdout.writer,
        &.{},
        noop_config_store.store(),
    );
    try server.run();

    const expected_body = try std.fmt.allocPrint(
        arena.allocator(),
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"{s}\",\"diagnostics\":[]}}}}",
        .{uri},
    );
    const expected = try std.fmt.allocPrint(
        arena.allocator(),
        "Content-Length: {d}\r\n\r\n{s}",
        .{ expected_body.len, expected_body },
    );
    try std.testing.expectEqualStrings(
        expected,
        stdout.written(),
    );
}

const std = @import("std");
const builtin = @import("builtin");
const LspResponse = @import("LspResponse.zig");
const LintSession = @import("../session/LintSession.zig");
const LintRuntime = @import("../session/LintRuntime.zig");
const testing = @import("../testing.zig");
const LspNotification = @import("LspNotification.zig");
const LspRequest = @import("LspRequest.zig");
const fileUriToAbsPath = @import("../files.zig").fileUriToAbsPath;
const FileStore = @import("../session/FileStore.zig");
const LintRule = @import("../rules.zig").LintRule;
const RuleIndex = @import("../rules.zig").RuleIndex;
const LintDocument = @import("../session/LintDocument.zig");
const LintConfigStore = @import("../session/LintConfigStore.zig");
const NoopLintConfigStore = @import("../session/NoopLintConfigStore.zig");
