//! Produces a zon file containing the dynamically generated rule configs.

const max_config_bytes = 1024 * 1024;

// const json_parse_options = std.json.ParseOptions{
//     .duplicate_field_behavior = .@"error",
//     .parse_numbers = true,
//     .ignore_unknown_fields = false,
//     .allocate = .alloc_always,
// };

/// Generates a rules config zig file at build time that can be built into the linter.
pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_allocator.deinit() == .leak) @panic("Memory leak");

    const gpa = debug_allocator.allocator();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const args = try std.process.argsAlloc(arena_allocator);
    if (args.len < 3) fatal("Wrong number of arguments - expected '<out file>' '<zon file>'", .{});

    const output_file_path = args[1];
    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |e| {
        fatal("Unable to open '{s}': {s}", .{ output_file_path, @errorName(e) });
    };
    defer output_file.close();

    const zon_file_path = args[2];
    const maybe_zon_file: ?std.fs.File = std.fs.cwd().openFile(zon_file_path, .{}) catch |e|
        switch (e) {
            error.FileNotFound => null,
            else => fatal("Unable to open '{s}': {s}", .{ zon_file_path, @errorName(e) }),
        };
    defer if (maybe_zon_file) |f| f.close();

    // const json_file_path = args[3];
    // const maybe_json_file: ?std.fs.File = std.fs.cwd().openFile(json_file_path, .{}) catch |e|
    //     switch (e) {
    //         error.FileNotFound => null,
    //         else => fatal("Unable to open '{s}': {s}", .{ json_file_path, @errorName(e) }),
    //     };
    // defer if (maybe_json_file) |f| f.close();

    var config: RulesConfig = .{};
    if (maybe_zon_file) |zon_file| {
        if (parseZon(zon_file, RulesConfig, arena_allocator)) |zon_config| {
            config = zon_config;
        } else |e| {
            fatal("Failed to parse zlinter config '{s}': {s}", .{ zon_file_path, @errorName(e) });
        }
    }
    // else if (maybe_json_file) |json_file| {
    //     const json = try parseJson(json_file, arena_allocator);
    //     for (rules) |rule| {
    //         inline for (std.meta.fields(RulesConfig)) |field| {
    //             if (std.mem.eql(u8, field.name, rule.rule_id)) {
    //                 if (try parseJsonKeyValue(json.value, field.name, field.type, arena_allocator)) |value| {
    //                     @field(config, field.name) = value;
    //                 }
    //             }
    //         }
    //     }
    // }

    const writer = output_file.writer();
    try std.zon.stringify.serialize(
        config,
        .{
            .whitespace = true,
            .emit_codepoint_literals = .always,
            .emit_default_optional_fields = true,
            .emit_strings_as_containers = false,
        },
        writer,
    );

    return std.process.cleanExit();
}

fn parseZon(zon_file: std.fs.File, comptime T: type, arena: std.mem.Allocator) !T {
    const content = try zon_file.readToEndAlloc(arena, max_config_bytes);
    const null_content = try arena.dupeZ(u8, content);

    var status: std.zon.parse.Status = .{};
    if (std.zon.parse.fromSlice(T, arena, null_content, &status, .{
        .free_on_error = true,
        .ignore_unknown_fields = false,
    })) |result| {
        return result;
    } else |e| {
        var writer = std.io.getStdErr().writer();
        try status.format("Failed to parse zlinter zon file", .{}, &writer);
        return e;
    }
}

// fn parseJson(json_file: std.fs.File, arena: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
//     const contents = try json_file.readToEndAlloc(arena, max_config_bytes);
//     return try std.json.parseFromSlice(std.json.Value, arena, contents, json_parse_options);
// }

// fn parseJsonKeyValue(json_value: std.json.Value, comptime key: []const u8, comptime T: type, arena: std.mem.Allocator) !?T {
//     return if (json_value.object.get(key)) |val|
//         (try std.json.parseFromValue(T, arena, val, json_parse_options)).value
//     else
//         null;
// }

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    std.process.exit(1);
}

const std = @import("std");
const RulesConfig = @import("rules").RulesConfig;
