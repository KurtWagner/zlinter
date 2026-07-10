const LspResponse = @This();

method_params: MethodParams,

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
    ) error{OutOfMemory}!?LspDiagnostic {
        const range = file_store.fileRange(
            file_id,
            problem.start.byte_offset,
            problem.end.byte_offset,
        );

        return .{
            .code = try arena.dupe(u8, problem.rule_id),
            .message = try arena.dupe(u8, problem.message),
            .severity = switch (problem.severity) {
                .off => return null,
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

    try jws.objectField("method");
    try jws.write(@tagName(std.meta.activeTag(self.method_params)));

    try jws.objectField("params");
    switch (self.method_params) {
        inline else => |payload| try jws.write(payload),
    }

    try jws.endObject();
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
        .method_params = .{
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

test {
    std.testing.refAllDecls(@This());
}

const testing = @import("../testing.zig");
const std = @import("std");
const FileId = @import("../session/FileStore.zig").FileId;
const FileStore = @import("../session/FileStore.zig");
const LintProblem = @import("../results.zig").LintProblem;
