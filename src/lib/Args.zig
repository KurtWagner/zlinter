//! Parsed from command line arguments passed to the lint executable.
const Args = @This();

/// Path to the zig executable used to build and run linter - needed for
/// analysing zig standard library.
zig_exe: ?[]const u8 = null,

/// Zig global cache path used to build and run linter - needed for
/// analysing zig standard library.
global_cache_root: ?[]const u8 = null,

/// Zig lib path used to build and run linter - needed for analysing zig
/// standard library.
zig_lib_directory: ?[]const u8 = null,

/// Indicates whether to run the linter in fix mode, where it'll attempt to
/// fix any discovered issues instead of reporting them.
fix: bool = false,

/// Only lint or fix (if using the fix argument) the given files. These
/// are owned by the struct and should be freed by calling deinit.
files: ?[][]const u8 = null,

/// Exclude these from linting. To add exclude paths, put an exclamation
/// in front of the path argument. This will only be set if at least one
/// exclude path exists. These are owned by the struct and should be freed by
/// calling deinit.
exclude_paths: ?[][]const u8 = null,

/// The format to print the lint result output in.
format: enum { default } = .default,

/// Contains any arguments that were found that unknown. When this happens
/// an error with the help does should be presented to the user as this
/// usually a user error that can be rectified. These are owned by the
/// struct and should be freed by calling deinit.
unknown_args: ?[][]const u8 = null,

/// Will contain rules that should be run. If unset, assume all rules
/// should be run. This can be used to focus a run on a single rule
rules: ?[][]const u8 = null,

pub fn deinit(self: Args, allocator: std.mem.Allocator) void {
    if (self.zig_exe) |zig_exe|
        allocator.free(zig_exe);

    if (self.global_cache_root) |global_cache_root|
        allocator.free(global_cache_root);

    if (self.zig_lib_directory) |zig_lib_directory|
        allocator.free(zig_lib_directory);

    if (self.files) |files| {
        for (files) |file| {
            allocator.free(file);
        }
        allocator.free(files);
    }

    if (self.exclude_paths) |exclude_paths| {
        for (exclude_paths) |path| {
            allocator.free(path);
        }
        allocator.free(exclude_paths);
    }

    if (self.unknown_args) |unknown_args| {
        for (unknown_args) |arg| {
            allocator.free(arg);
        }
        allocator.free(unknown_args);
    }

    if (self.rules) |rules| {
        for (rules) |rule| allocator.free(rule);
        allocator.free(rules);
    }
}

pub fn allocParse(args: [][:0]u8, available_rules: []const LintRule, allocator: std.mem.Allocator) !Args {
    var index: usize = 0;
    var arg: [:0]u8 = undefined;

    var lint_args = Args{};

    var unknown_args = std.ArrayListUnmanaged([]const u8).empty;
    defer unknown_args.deinit(allocator);

    var files = std.ArrayListUnmanaged([]const u8).empty;
    defer files.deinit(allocator);
    errdefer for (files.items) |p| allocator.free(p);

    var exclude_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer exclude_paths.deinit(allocator);
    errdefer for (exclude_paths.items) |p| allocator.free(p);

    var rules = std.ArrayListUnmanaged([]const u8).empty;
    defer rules.deinit(allocator);

    var stderr_writer = std.io.getStdErr().writer();

    const State = enum {
        parsing,
        fix_arg,
        zig_exe_arg,
        zig_lib_directory_arg,
        global_cache_root_arg,
        unknown_arg,
        format_arg,
        file_arg,
        rule_arg,
        exclude_arg,
    };

    state: switch (State.parsing) {
        .parsing => {
            index += 1; // ignore first arg as this is the binary.
            if (index < args.len) {
                arg = args[index];
                if (std.mem.eql(u8, arg, "--fix")) {
                    continue :state State.fix_arg;
                } else if (std.mem.eql(u8, arg, "--rule")) {
                    continue :state State.rule_arg;
                } else if (std.mem.eql(u8, arg, "--exclude")) {
                    continue :state State.exclude_arg;
                } else if (std.mem.eql(u8, arg, "--zig_exe")) {
                    continue :state State.zig_exe_arg;
                } else if (std.mem.eql(u8, arg, "--zig_lib_directory")) {
                    continue :state State.zig_lib_directory_arg;
                } else if (std.mem.eql(u8, arg, "--global_cache_root")) {
                    continue :state State.global_cache_root_arg;
                } else if (std.mem.eql(u8, arg, "--format")) {
                    continue :state State.format_arg;
                } else if (std.mem.startsWith(u8, arg, "-")) {
                    continue :state State.unknown_arg;
                }
                continue :state State.file_arg;
            }
        },
        .zig_exe_arg => {
            index += 1;
            if (index == args.len) {
                stderr_writer.print("--zig_exe missing path\n", .{}) catch {};
                return error.InvalidArgs;
            }
            lint_args.zig_exe = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .zig_lib_directory_arg => {
            index += 1;
            if (index == args.len) {
                stderr_writer.print("--zig_lib_directory missing path\n", .{}) catch {};
                return error.InvalidArgs;
            }
            lint_args.zig_lib_directory = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .global_cache_root_arg => {
            index += 1;
            if (index == args.len) {
                stderr_writer.print("--global_cache_root missing path\n", .{}) catch {};
                return error.InvalidArgs;
            }
            lint_args.global_cache_root = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .rule_arg => {
            index += 1;
            if (index == args.len) {
                stderr_writer.print("--rule missing rule name\n", .{}) catch {};
                return error.InvalidArgs;
            }

            const rule_exists: bool = exists: {
                for (available_rules) |available_rule| {
                    if (std.mem.eql(u8, available_rule.rule_id, args[index])) break :exists true;
                }
                break :exists false;
            };
            if (!rule_exists) {
                stderr_writer.print("rule '{s}' not found\n", .{args[index]}) catch {};
                return error.InvalidArgs;
            }

            try rules.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state State.parsing;
        },
        .exclude_arg => {
            index += 1;
            if (index == args.len) {
                stderr_writer.print("--exclude arg missing expression\n", .{}) catch {};
                return error.InvalidArgs;
            }
            try exclude_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state State.parsing;
        },
        .format_arg => {
            index += 1;
            if (index == args.len) {
                stderr_writer.print("--format missing path\n", .{}) catch {};
                return error.InvalidArgs;
            }
            inline for (std.meta.fields(@FieldType(Args, "format"))) |field| {
                if (std.mem.eql(u8, args[index], field.name)) {
                    lint_args.format = @enumFromInt(field.value);
                    continue :state State.parsing;
                }
            }
            stderr_writer.print("--format only supports: {s}\n", .{comptime formats: {
                var formats: []u8 = "";
                for (std.meta.fieldNames(@FieldType(Args, "format"))) |name| {
                    formats = @constCast(formats ++ name ++ " ");
                }
                break :formats formats;
            }}) catch {};
            return error.InvalidArgs;
        },
        .fix_arg => {
            lint_args.fix = true;
            continue :state State.parsing;
        },
        .unknown_arg => {
            try unknown_args.append(allocator, try allocator.dupe(u8, arg));
            continue :state State.parsing;
        },
        .file_arg => {
            try files.append(allocator, try allocator.dupe(u8, arg[0..]));
            continue :state State.parsing;
        },
    }

    if (unknown_args.items.len > 0) {
        lint_args.unknown_args = try unknown_args.toOwnedSlice(allocator);
    }
    if (files.items.len > 0) {
        lint_args.files = try files.toOwnedSlice(allocator);
    }
    if (exclude_paths.items.len > 0) {
        lint_args.exclude_paths = try exclude_paths.toOwnedSlice(allocator);
    }
    if (rules.items.len > 0) {
        lint_args.rules = try rules.toOwnedSlice(allocator);
    }

    return lint_args;
}

test "allocParse with unknown args" {
    const args = try allocParse(
        testing.cliArgs(&.{ "-", "-fix", "--a" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .files = null,
        .unknown_args = @constCast(&[_][]const u8{ "-", "-fix", "--a" }),
    }, args);
}

test "allocParse with fix arg" {
    const args = try allocParse(
        testing.cliArgs(&.{"--fix"}),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
        .files = null,
        .unknown_args = null,
    }, args);
}

test "allocParse with fix arg and files" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "a/b.zig", "./c.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
        .files = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
        .unknown_args = null,
    }, args);
}

test "allocParse with duplicate files files" {
    const args = try allocParse(
        testing.cliArgs(&.{ "a/b.zig", "a/b.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .files = @constCast(&[_][]const u8{ "a/b.zig", "a/b.zig" }),
        .unknown_args = null,
    }, args);
}

test "allocParse with files" {
    const args = try allocParse(
        testing.cliArgs(&.{ "a/b.zig", "./c.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .files = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
        .unknown_args = null,
    }, args);
}

test "allocParse with exclude files" {
    const args = try allocParse(
        testing.cliArgs(&.{
            "--exclude",
            "a/b.zig",
            "--exclude",
            "./c.zig",
            "--exclude",
            "d.zig",
        }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        .unknown_args = null,
    }, args);
}

test "allocParse with exclude and include files" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--exclude", "a/b.zig", "./c.zig", "--exclude", "d.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "d.zig" }),
        .files = @constCast(&[_][]const u8{"./c.zig"}),
        .unknown_args = null,
    }, args);
}

test "allocParse with all combinations" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--unknown", "a/b.zig", "./c.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
        .files = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
        .unknown_args = @constCast(&[_][]const u8{
            "--unknown",
        }),
    }, args);
}

test "allocParse with zig_exe arg" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--zig_exe", "/some/path here/zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .zig_exe = "/some/path here/zig",
    }, args);
}

test "allocParse with global_cache_root arg" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--global_cache_root", "/some/path here/cache" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .global_cache_root = "/some/path here/cache",
    }, args);
}

test "allocParse with zig_lib_directory arg" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--zig_lib_directory", "/some/path here/lib" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .zig_lib_directory = "/some/path here/lib",
    }, args);
}

test "allocParse with format arg" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--format", "default" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .format = .default,
    }, args);
}

test "allocParse with rule arg" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--rule", "my_rule" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .rules = @constCast(&[_][]const u8{"my_rule"}),
    }, args);
}

test "allocParse with invalid rule arg" {
    // TODO: Capture stderr and test it instead of using log.err
    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{ "--rule", "not_found_rule" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
    ));
}

test "allocParse without args" {
    const args = try allocParse(
        testing.cliArgs(&.{}),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{}, args);
}

test "allocParse fuzz" {
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));

    const max_args = 10;

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var buffer: [1024]u8 = undefined;

    var mem: [(buffer.len + 1) * max_args]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    for (0..1000) |_| {
        defer fba.reset();

        var raw_args: [max_args][:0]u8 = undefined;
        for (0..raw_args.len) |i| {
            rand.bytes(&buffer);
            raw_args[i] = try fba.allocator().dupeZ(u8, buffer[0..]);
        }

        const args = try allocParse(
            &raw_args,
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);
    }
}

const testing = struct {
    inline fn cliArgs(args: []const [:0]const u8) [][:0]u8 {
        assertTestOnly();

        var casted: [args.len + 1][:0]u8 = undefined;
        casted[0] = @constCast("lint-exe");
        for (0..args.len) |i| casted[i + 1] = @constCast(args[i]);
        return &casted;
    }

    inline fn assertTestOnly() void {
        comptime if (!builtin.is_test) @compileError("Test only");
    }
};

const std = @import("std");
const builtin = @import("builtin");
const LintRule = @import("./linting.zig").LintRule;
