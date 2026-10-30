//! Common utilities used in testing.

pub const Format = enum { json, zon };

/// Compare generic parsed values, ignoring formatting and object field order.
/// Array order and value types remain significant.
pub fn equal(
    gpa: std.mem.Allocator,
    format: Format,
    expected: []const u8,
    actual: []const u8,
) !bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (format) {
        .json => {
            const expected_value = try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena,
                expected,
                .{},
            );

            const actual_value = try std.json.parseFromSliceLeaky(
                std.json.Value,
                arena,
                actual,
                .{},
            );

            return jsonEqual(
                expected_value,
                actual_value,
            );
        },
        .zon => {
            const expected_value = try parseZon(
                arena,
                expected,
            );

            const actual_value = try parseZon(
                arena,
                actual,
            );

            return zonEqual(
                &expected_value,
                .root,
                &actual_value,
                .root,
            );
        },
    }
}

fn jsonEqual(expected: std.json.Value, actual: std.json.Value) bool {
    if (std.meta.activeTag(expected) != std.meta.activeTag(actual))
        return false;

    return switch (expected) {
        .null => true,
        .bool => |value| value == actual.bool,
        .integer => |value| value == actual.integer,
        .float => |value| value == actual.float,
        .number_string => |value| std.mem.eql(
            u8,
            value,
            actual.number_string,
        ),
        .string => |value| std.mem.eql(
            u8,
            value,
            actual.string,
        ),
        .array => |value| blk: {
            if (value.items.len != actual.array.items.len) break :blk false;
            for (value.items, actual.array.items) |a, b|
                if (!jsonEqual(a, b)) break :blk false;
            break :blk true;
        },
        .object => |value| blk: {
            if (value.count() != actual.object.count()) break :blk false;
            for (value.keys(), value.values()) |key, child|
                if (!jsonEqual(
                    child,
                    actual.object.get(key) orelse break :blk false,
                ))
                    break :blk false;
            break :blk true;
        },
    };
}

fn parseZon(arena: std.mem.Allocator, source: []const u8) !std.zig.Zoir {
    const terminated = try arena.dupeSentinel(
        u8,
        source,
        0,
    );
    const ast = try std.zig.Ast.parse(
        arena,
        terminated,
        .{ .mode = .zon },
    );
    if (ast.errors.len != 0) return error.ParseZon;
    const zoir = try std.zig.ZonGen.generate(
        arena,
        ast,
        .{},
    );
    if (zoir.hasCompileErrors()) return error.ParseZon;
    return zoir;
}

fn zonEqual(
    expected: *const std.zig.Zoir,
    expected_index: std.zig.Zoir.Node.Index,
    actual: *const std.zig.Zoir,
    actual_index: std.zig.Zoir.Node.Index,
) bool {
    const a = expected_index.get(expected);
    const b = actual_index.get(actual);
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .true, .false, .null, .pos_inf, .neg_inf, .nan, .empty_literal => true,
        .int_literal => |value| switch (value) {
            .small => |number| b.int_literal == .small and number == b.int_literal.small,
            .big => |number| b.int_literal == .big and number.eql(b.int_literal.big),
        },
        .float_literal => |value| value == b.float_literal,
        .char_literal => |value| value == b.char_literal,
        .enum_literal => |value| std.mem.eql(
            u8,
            value.get(expected),
            b.enum_literal.get(actual),
        ),
        .string_literal => |value| std.mem.eql(u8, value, b.string_literal),
        .array_literal => |value| blk: {
            if (value.len != b.array_literal.len) break :blk false;
            for (0..value.len) |i|
                if (!zonEqual(
                    expected,
                    value.at(@intCast(i)),
                    actual,
                    b.array_literal.at(@intCast(i)),
                )) break :blk false;
            break :blk true;
        },
        .struct_literal => |value| blk: {
            if (value.names.len != b.struct_literal.names.len) break :blk false;
            for (value.names, 0..) |name, i|
                fields: for (b.struct_literal.names, 0..) |other_name, j| {
                    if (!std.mem.eql(
                        u8,
                        name.get(expected),
                        other_name.get(actual),
                    )) continue :fields;
                    if (!zonEqual(
                        expected,
                        value.vals.at(@intCast(i)),
                        actual,
                        b.struct_literal.vals.at(@intCast(j)),
                    )) break :blk false;
                    break;
                } else break :blk false;
            break :blk true;
        },
    };
}

test "JSON comparison ignores formatting, escapes and field order" {
    try std.testing.expect(try equal(std.testing.allocator, .json,
        \\{ "items": [{"name": "a", "count": 2}], "empty": {}, "optional": null }
    ,
        \\{"optional":null,"empty":{},"items":[{"count":2,"name":"\u0061"}]}
    ));
}

test "ZON comparison ignores comments, formatting, escapes and field order" {
    try std.testing.expect(try equal(std.testing.allocator, .zon,
        \\.{ .items = .{.{ .name = "a", .count = 2 }}, .empty = .{}, .optional = null }
    ,
        \\// A formatted fixture can differ from compact output.
        \\.{
        \\    .optional = null,
        \\    .empty = .{},
        \\    .items = .{.{ .count = 0x2, .name = "\x61" }},
        \\}
    ));
}

test "comparison detects different values, types, fields and array order" {
    const cases = .{
        .{ Format.json, "[1,2]", "[2,1]" },
        .{ Format.json, "[1]", "[1,2]" },
        .{ Format.json, "1", "\"1\"" },
        .{ Format.json, "{\"a\":1}", "{\"a\":2}" },
        .{ Format.json, "{\"a\":1}", "{\"b\":1}" },
        .{ Format.json, "{\"a\":1}", "{\"a\":1,\"b\":2}" },
        .{ Format.zon, ".{1,2}", ".{2,1}" },
        .{ Format.zon, ".{1}", ".{1,2}" },
        .{ Format.zon, "1", "\"1\"" },
        .{ Format.zon, ".{.a=1}", ".{.a=2}" },
        .{ Format.zon, ".{.a=1}", ".{.b=1}" },
        .{ Format.zon, ".{.a=1}", ".{.a=1,.b=2}" },
    };
    inline for (cases) |case|
        try std.testing.expect(!try equal(std.testing.allocator, case[0], case[1], case[2]));
}

test "comparison rejects invalid serialized values on either side" {
    try std.testing.expectError(error.UnexpectedEndOfInput, equal(std.testing.allocator, .json, "{", "{}"));
    try std.testing.expectError(error.UnexpectedEndOfInput, equal(std.testing.allocator, .json, "{}", "{"));
    try std.testing.expectError(error.ParseZon, equal(std.testing.allocator, .zon, ".{", ".{}"));
    try std.testing.expectError(error.ParseZon, equal(std.testing.allocator, .zon, ".{}", ".{"));
    try std.testing.expectError(error.ParseZon, equal(std.testing.allocator, .zon, ".{}", ".{.a=1,.a=2}"));
}

const std = @import("std");
