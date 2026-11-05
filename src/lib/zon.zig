pub const Diagnostics = switch (version.zig) {
    .@"0.13" => CustomDiagnostics,
    .@"0.14" => std.zon.parse.Status,
    .@"0.15", .@"0.16" => std.zon.parse.Diagnostics,
};

pub const CustomDiagnostics = struct {
    errors: [32]Error = undefined,
    error_count: usize = 0,

    pub const Error = struct {
        msg: []const u8,
    };

    pub fn add(self: *CustomDiagnostics, msg: []const u8) void {
        if (self.error_count < self.errors.len) {
            self.errors[self.error_count] = .{ .msg = msg };
            self.error_count += 1;
        }
    }

    pub fn iterateErrors(self: *CustomDiagnostics) ErrorIterator {
        return .{ .diagnostics = self, .index = 0 };
    }

    pub const ErrorIterator = struct {
        diagnostics: *CustomDiagnostics,
        index: usize,

        pub fn next(self: *ErrorIterator) ?Error {
            if (self.index >= self.diagnostics.error_count) return null;
            const err = self.diagnostics.errors[self.index];
            self.index += 1;
            return err;
        }
    };

    pub fn format(
        self: CustomDiagnostics,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        for (self.errors[0..self.error_count]) |err| {
            try writer.print("{s}\n", .{err.msg});
        }
    }
};

pub fn parseFileAlloc(
    T: type,
    dir: std.fs.Dir,
    cwd_file_path: []const u8,
    diagnostics: ?*Diagnostics,
    gpa: std.mem.Allocator,
) !T {
    const file = try dir.openFile(cwd_file_path, .{
        .mode = .read_only,
    });
    defer file.close();

    var array_list = std.ArrayList(u8).init(gpa);
    defer array_list.deinit();

    var file_reader = file.reader();
    try file_reader.readAllArrayList(
        &array_list,
        session.max_zig_file_size_bytes,
    );
    const null_terminated = try array_list.toOwnedSliceSentinel(0);
    defer gpa.free(null_terminated);

    return parseFromSlice(T, gpa, null_terminated, diagnostics);
}

pub fn parseFromSlice(
    T: type,
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    diagnostics: ?*Diagnostics,
) !T {
    var parser = Parser.init(gpa, source, diagnostics);
    return parser.parse(T);
}

const Parser = struct {
    gpa: std.mem.Allocator,
    source: [:0]const u8,
    pos: usize = 0,
    diagnostics: ?*CustomDiagnostics,

    fn init(gpa: std.mem.Allocator, source: [:0]const u8, diagnostics: ?*CustomDiagnostics) Parser {
        return .{
            .gpa = gpa,
            .source = source,
            .pos = 0,
            .diagnostics = diagnostics,
        };
    }

    fn addError(self: *Parser, msg: []const u8) error{ParseZon} {
        if (self.diagnostics) |d| d.add(msg);
        return error.ParseZon;
    }

    fn addErrorFmt(self: *Parser, comptime fmt: []const u8, args: anytype) error{ParseZon} {
        if (self.diagnostics) |d| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, fmt, args) catch {
                d.add("parse error");
                return error.ParseZon;
            };
            d.add(msg);
        }
        return error.ParseZon;
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else {
                break;
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.source.len) return null;
        return self.source[self.pos];
    }

    fn expect(self: *Parser, char: u8) !void {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return error.ParseZon;
        if (self.source[self.pos] != char) return error.ParseZon;
        self.pos += 1;
    }

    fn eat(self: *Parser, char: u8) bool {
        self.skipWhitespace();
        if (self.pos < self.source.len and self.source[self.pos] == char) {
            self.pos += 1;
            return true;
        }
        return false;
    }

    fn parseIdentifier(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        if (self.pos < self.source.len and self.source[self.pos] == '@') {
            self.pos += 1;
            try self.expect('"');
            const start = self.pos;
            while (self.pos < self.source.len and self.source[self.pos] != '"') {
                self.pos += 1;
            }
            if (self.pos >= self.source.len) return error.ParseZon;
            const result = self.source[start..self.pos];
            self.pos += 1;
            return result;
        }
        const start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (std.ascii.isAlphabetic(c) or c == '_' or (self.pos > start and std.ascii.isDigit(c))) {
                self.pos += 1;
            } else {
                break;
            }
        }
        if (self.pos == start) return error.ParseZon;
        return self.source[start..self.pos];
    }

    fn parseString(self: *Parser) ![]const u8 {
        self.skipWhitespace();
        if (self.pos >= self.source.len or self.source[self.pos] != '"') return error.ParseZon;
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                const result = self.source[start..self.pos];
                self.pos += 1;
                return try self.gpa.dupe(u8, result);
            }
            if (c == '\\') {
                self.pos += 2;
            } else {
                self.pos += 1;
            }
        }
        return error.ParseZon;
    }

    fn parseNumber(self: *Parser) !i128 {
        self.skipWhitespace();
        const start = self.pos;
        if (self.pos < self.source.len and self.source[self.pos] == '-') {
            self.pos += 1;
        }
        while (self.pos < self.source.len and std.ascii.isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        if (self.pos == start) return error.ParseZon;
        const num_str = self.source[start..self.pos];
        return std.fmt.parseInt(i128, num_str, 10) catch return error.ParseZon;
    }

    fn parseBool(self: *Parser) !bool {
        self.skipWhitespace();
        if (self.pos + 4 <= self.source.len and std.mem.eql(u8, self.source[self.pos..][0..4], "true")) {
            self.pos += 4;
            return true;
        }
        if (self.pos + 5 <= self.source.len and std.mem.eql(u8, self.source[self.pos..][0..5], "false")) {
            self.pos += 5;
            return false;
        }
        return error.ParseZon;
    }

    fn parse(self: *Parser, T: type) !T {
        return self.parseValue(T);
    }

    fn parseValue(self: *Parser, T: type) !T {
        const info: std.builtin.Type = @typeInfo(T);
        switch (info) {
            .Struct => return self.parseStruct(T),
            .Enum => return self.parseEnum(T),
            .Bool => {
                const val = try self.parseBool();
                return val;
            },
            .Int, .ComptimeInt => {
                const num = try self.parseNumber();
                return std.math.cast(T, num) orelse error.ParseZon;
            },
            .Float, .ComptimeFloat => {
                self.skipWhitespace();
                const start = self.pos;
                if (self.pos < self.source.len and self.source[self.pos] == '-') self.pos += 1;
                while (self.pos < self.source.len) {
                    const c = self.source[self.pos];
                    if (std.ascii.isDigit(c) or c == '.') {
                        self.pos += 1;
                    } else {
                        break;
                    }
                }
                const num_str = self.source[start..self.pos];
                const val = std.fmt.parseFloat(T, num_str) catch return error.ParseZon;
                return val;
            },
            .Pointer => |ptr| {
                switch (ptr.size) {
                    .Slice => {
                        if (ptr.child == u8) {
                            return self.parseString();
                        }
                        return self.parseSlice(T);
                    },
                    .One => {
                        return self.parseValue(ptr.child);
                    },
                    else => return error.ParseZon,
                }
            },
            .Optional => |opt| {
                self.skipWhitespace();
                if (self.pos + 4 <= self.source.len and std.mem.eql(u8, self.source[self.pos..][0..4], "null")) {
                    self.pos += 4;
                    return null;
                }
                return try self.parseValue(opt.child);
            },
            else => return error.ParseZon,
        }
    }

    fn parseStruct(self: *Parser, T: type) !T {
        var result: T = undefined;
        const fields = std.meta.fields(T);

        inline for (fields) |field| {
            if (field.default_value) |default_ptr| {
                const default: field.type = @as(*const field.type, @ptrCast(@alignCast(default_ptr))).*;
                @field(result, field.name) = default;
            } else {
                @field(result, field.name) = undefined;
            }
        }

        if (!self.eat('.')) return error.ParseZon;
        try self.expect('{');

        if (self.eat('}')) return result;

        while (true) {
            try self.expect('.');
            const field_name = try self.parseIdentifier();
            try self.expect('=');

            var found = false;
            inline for (fields) |field| {
                if (std.mem.eql(u8, field.name, field_name)) {
                    found = true;
                    @field(result, field.name) = try self.parseValue(field.type);
                    break;
                }
            }
            if (!found) {
                return self.addErrorFmt("Unknown field '{s}'", .{field_name});
            }

            if (self.eat(',')) {
                if (self.eat('}')) return result;
                continue;
            }
            try self.expect('}');
            return result;
        }
    }

    fn parseEnum(self: *Parser, T: type) !T {
        try self.expect('.');
        const name = try self.parseIdentifier();
        const fields = std.meta.fields(T);
        inline for (fields) |field| {
            if (std.mem.eql(u8, field.name, name)) {
                return @enumFromInt(field.value);
            }
        }
        return self.addErrorFmt("Unknown enum field '.{s}'", .{name});
    }

    fn parseSlice(self: *Parser, T: type) !T {
        const info: std.builtin.Type = @typeInfo(T);
        const child = info.Pointer.child;

        if (self.eat('&')) {
            // &.{ ... } syntax
        }
        if (!self.eat('.')) return error.ParseZon;
        try self.expect('{');

        var items = std.ArrayList(child).init(self.gpa);
        defer items.deinit();

        if (self.eat('}')) {
            return items.toOwnedSlice();
        }

        while (true) {
            const val = try self.parseValue(child);
            try items.append(val);

            if (self.eat(',')) {
                if (self.eat('}')) break;
                continue;
            }
            try self.expect('}');
            break;
        }

        return items.toOwnedSlice();
    }
};

test "parseFileAlloc" {
    const BasicStruct = struct {
        age: u32 = 10,
        names: []const []const u8 = &.{ "a", "b" },
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var tmp_dir = std.testing.tmpDir(.{});

    defer tmp_dir.cleanup();

    try testing.writeFile(
        tmp_dir.dir,
        "a.zon",
        \\.{}
        ,
    );
    try std.testing.expectEqualDeep(
        BasicStruct{},
        try parseFileAlloc(
            BasicStruct,
            tmp_dir.dir,
            "a.zon",
            null,
            arena.allocator(),
        ),
    );

    try testing.writeFile(
        tmp_dir.dir,
        "b.zon",
        \\.{
        \\ .age = 20,
        \\ .names = .{"c", "d"},
        \\}
        ,
    );
    try std.testing.expectEqualDeep(
        BasicStruct{
            .age = 20,
            .names = &.{ "c", "d" },
        },
        try parseFileAlloc(
            BasicStruct,
            tmp_dir.dir,
            "b.zon",
            null,
            arena.allocator(),
        ),
    );

    var diagnostics = CustomDiagnostics{};
    try testing.writeFile(
        tmp_dir.dir,
        "b.zon",
        \\.{ .not_found = 10 }
        ,
    );
    const actual = parseFileAlloc(
        BasicStruct,
        tmp_dir.dir,
        "b.zon",
        &diagnostics,
        arena.allocator(),
    );
    try std.testing.expectError(
        error.ParseZon,
        actual,
    );

    var it = diagnostics.iterateErrors();
    try std.testing.expect(it.next() != null);
    try std.testing.expect(it.next() == null);
}


pub const stringify = struct {
    pub fn serialize(val: anytype, writer: anytype) !void {
        try serializeInternal(val, writer, false);
    }

    pub fn serializeZig(val: anytype, writer: anytype) !void {
        try serializeInternal(val, writer, true);
    }

    fn serializeInternal(val: anytype, writer: anytype, comptime zig_mode: bool) !void {
        const T = @TypeOf(val);
        const info: std.builtin.Type = @typeInfo(T);

        switch (info) {
            .Struct => |s| {
                try writer.writeAll(".{");
                inline for (s.fields, 0..) |field, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try writer.print(".{s} = ", .{field.name});
                    try serializeInternal(@field(val, field.name), writer, zig_mode);
                }
                try writer.writeAll("}");
            },
            .Optional => |_| {
                if (val) |v| {
                    try serializeInternal(v, writer, zig_mode);
                } else {
                    try writer.writeAll("null");
                }
            },
            .Pointer => |ptr| {
                switch (ptr.size) {
                    .Slice => {
                        if (ptr.child == u8) {
                            try writeZonString(val, writer);
                        } else {
                            if (zig_mode) {
                                try writer.writeAll("&.{");
                            } else {
                                try writer.writeAll(".{");
                            }
                            for (val, 0..) |item, i| {
                                if (i > 0) try writer.writeAll(", ");
                                try serializeInternal(item, writer, zig_mode);
                            }
                            try writer.writeAll("}");
                        }
                    },
                    .One => {
                        switch (@typeInfo(ptr.child)) {
                            .Array => |arr| {
                                if (arr.child == u8) {
                                    try writeZonString(val.*[0..], writer);
                                } else {
                                    try serializeInternal(val.*, writer, zig_mode);
                                }
                            },
                            else => try serializeInternal(val.*, writer, zig_mode),
                        }
                    },
                    else => @compileError("Unsupported pointer type in ZON serialization"),
                }
            },
            .Array => |arr| {
                _ = arr;
                if (zig_mode) {
                    try writer.writeAll("&.{");
                } else {
                    try writer.writeAll(".{");
                }
                for (val, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    try serializeInternal(item, writer, zig_mode);
                }
                try writer.writeAll("}");
            },
            .Enum => {
                try writeEnumLiteral(@tagName(val), writer, zig_mode);
            },
            .EnumLiteral => {
                try writeEnumLiteral(@tagName(val), writer, zig_mode);
            },
            .Bool => {
                try writer.writeAll(if (val) "true" else "false");
            },
            .Int, .ComptimeInt => {
                try writer.print("{d}", .{val});
            },
            .Float, .ComptimeFloat => {
                try writer.print("{d}", .{val});
            },
            else => @compileError("Unsupported type in ZON serialization: " ++ @typeName(T)),
        }
    }

    fn writeEnumLiteral(name: []const u8, writer: anytype, comptime zig_mode: bool) !void {
        if (zig_mode and isZigKeyword(name)) {
            try writer.print(".@\"{s}\"", .{name});
        } else {
            try writer.print(".{s}", .{name});
        }
    }

    fn isZigKeyword(name: []const u8) bool {
        const keywords = [_][]const u8{
            "addrspace", "align", "allowzero", "and", "anyframe", "anytype",
            "asm", "async", "await", "break", "callconv", "catch", "comptime",
            "const", "continue", "defer", "else", "enum", "errdefer", "error",
            "export", "extern", "false", "fn", "for", "if", "inline", "noalias",
            "noinline", "nosuspend", "null", "opaque", "or", "orelse", "packed",
            "pub", "resume", "return", "linksection", "struct", "suspend",
            "switch", "test", "threadlocal", "true", "try", "type", "undefined",
            "union", "unreachable", "usingnamespace", "var", "volatile", "while",
        };
        for (keywords) |kw| {
            if (std.mem.eql(u8, name, kw)) return true;
        }
        return false;
    }

    fn writeZonString(str: []const u8, writer: anytype) !void {
        try writer.writeAll("\"");
        for (str) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(c),
            }
        }
        try writer.writeAll("\"");
    }
};

const session = @import("session.zig");
const std = @import("std");
const testing = @import("testing.zig");
const version = @import("version.zig");
