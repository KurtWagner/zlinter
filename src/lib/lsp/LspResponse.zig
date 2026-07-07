const LspResponse = @This();

method_params: MethodParams,

// zlinter-disable field_naming - we don't control the method names
const Method = enum {
    @"textDocument/publishDiagnostics",
};
// zlinter-enable field_naming

// zlinter-disable field_naming - we don't control the method names
const MethodParams = union(Method) {
    @"textDocument/publishDiagnostics": struct {
        uri: []const u8,
        diagnostics: []const LspDiagnostic,
    },
};
// zlinter-enable field_naming

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
        arena: std.mem.Allocator,
    ) error{OutOfMemory}!?LspDiagnostic {
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
                    .line = 0, // TODO: Hook up line and character
                    .character = 0,
                },
                .end = .{
                    .line = 0, // TODO: Hook up line and character
                    .character = 0,
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

test "textDocument/publishDiagnostics json" {
    const response: LspResponse = .{
        .method_params = .{
            .@"textDocument/publishDiagnostics" = .{
                .uri = "file://fake/file.zig",
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
const LintProblem = @import("../results.zig").LintProblem;
