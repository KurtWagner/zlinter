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
/// are owned by the struct and should be freed by calling deinit. This will
/// replace any file resolution provided by the build file.
/// /// This is populated with the `--include <path>` flag.
include_paths: ?[][]const u8 = null,

/// Similar to `files` but will be used to filter out files after resolution.
/// This is populated with the `--filter <path>` flag.
filter_paths: ?[][]const u8 = null,

/// Exclude these from linting irrespective of how the files were resolved.
/// This is populated with the `--exclude <path>` flag.
exclude_paths: ?[][]const u8 = null,

/// Similar to `exclude_paths` but is populated by the build runner using the
/// flag `--build-exclude`. This should never be used by an end user of the CLI.
build_exclude_paths: ?[][]const u8 = null,

/// Similar to `include_paths` but is populated by the build runner using the
/// flag `--build-include`. This should never be used by an end user of the CLI.
build_include_paths: ?[][]const u8 = null,

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

/// Whether to write additional information out to stdout.
verbose: bool = false,

pub fn deinit(self: Args, allocator: std.mem.Allocator) void {
    if (self.zig_exe) |zig_exe|
        allocator.free(zig_exe);

    if (self.global_cache_root) |global_cache_root|
        allocator.free(global_cache_root);

    if (self.zig_lib_directory) |zig_lib_directory|
        allocator.free(zig_lib_directory);

    if (self.include_paths) |paths| {
        for (paths) |file| {
            allocator.free(file);
        }
        allocator.free(paths);
    }

    if (self.exclude_paths) |paths| {
        for (paths) |path| {
            allocator.free(path);
        }
        allocator.free(paths);
    }

    if (self.build_include_paths) |paths| {
        for (paths) |file| {
            allocator.free(file);
        }
        allocator.free(paths);
    }

    if (self.build_exclude_paths) |paths| {
        for (paths) |path| {
            allocator.free(path);
        }
        allocator.free(paths);
    }

    if (self.filter_paths) |paths| {
        for (paths) |path| {
            allocator.free(path);
        }
        allocator.free(paths);
    }

    if (self.unknown_args) |args| {
        for (args) |arg| {
            allocator.free(arg);
        }
        allocator.free(args);
    }

    if (self.rules) |rules| {
        for (rules) |rule| allocator.free(rule);
        allocator.free(rules);
    }
}

pub fn allocParse(
    args: [][:0]u8,
    available_rules: []const LintRule,
    allocator: std.mem.Allocator,
) error{ OutOfMemory, InvalidArgs }!Args {
    var index: usize = 0;
    var arg: [:0]u8 = undefined;

    var lint_args = Args{};

    var unknown_args = std.ArrayListUnmanaged([]const u8).empty;
    defer unknown_args.deinit(allocator);

    var include_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer include_paths.deinit(allocator);
    errdefer for (include_paths.items) |p| allocator.free(p);

    var exclude_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer exclude_paths.deinit(allocator);
    errdefer for (exclude_paths.items) |p| allocator.free(p);

    var build_include_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer build_include_paths.deinit(allocator);
    errdefer for (build_include_paths.items) |p| allocator.free(p);

    var build_exclude_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer build_exclude_paths.deinit(allocator);
    errdefer for (build_exclude_paths.items) |p| allocator.free(p);

    var filter_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer filter_paths.deinit(allocator);
    errdefer for (filter_paths.items) |p| allocator.free(p);

    var rules = std.ArrayListUnmanaged([]const u8).empty;
    defer rules.deinit(allocator);

    const State = enum {
        parsing,
        fix_arg,
        verbose_arg,
        zig_exe_arg,
        zig_lib_directory_arg,
        global_cache_root_arg,
        unknown_arg,
        format_arg,
        rule_arg,
        filter_path_arg,
        include_path_arg,
        exclude_path_arg,
        build_include_path_arg,
        build_exclude_path_arg,
    };

    state: switch (State.parsing) {
        .parsing => {
            index += 1; // ignore first arg as this is the binary.
            if (index < args.len) {
                arg = args[index];
                if (arg.len == 0)
                    continue :state .parsing
                else if (std.mem.eql(u8, arg, "--fix")) {
                    continue :state State.fix_arg;
                } else if (std.mem.eql(u8, arg, "--verbose")) {
                    continue :state State.verbose_arg;
                } else if (std.mem.eql(u8, arg, "--rule")) {
                    continue :state State.rule_arg;
                } else if (std.mem.eql(u8, arg, "--include")) {
                    continue :state State.include_path_arg;
                } else if (std.mem.eql(u8, arg, "--exclude")) {
                    continue :state State.exclude_path_arg;
                } else if (std.mem.eql(u8, arg, "--build-include")) {
                    continue :state State.build_include_path_arg;
                } else if (std.mem.eql(u8, arg, "--build-exclude")) {
                    continue :state State.build_exclude_path_arg;
                } else if (std.mem.eql(u8, arg, "--filter")) {
                    continue :state State.filter_path_arg;
                } else if (std.mem.eql(u8, arg, "--zig_exe")) {
                    continue :state State.zig_exe_arg;
                } else if (std.mem.eql(u8, arg, "--zig_lib_directory")) {
                    continue :state State.zig_lib_directory_arg;
                } else if (std.mem.eql(u8, arg, "--global_cache_root")) {
                    continue :state State.global_cache_root_arg;
                } else if (std.mem.eql(u8, arg, "--format")) {
                    continue :state State.format_arg;
                }
                continue :state State.unknown_arg;
            }
        },
        .zig_exe_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--zig_exe missing path", .{});
                return error.InvalidArgs;
            }
            lint_args.zig_exe = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .zig_lib_directory_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--zig_lib_directory missing path", .{});
                return error.InvalidArgs;
            }
            lint_args.zig_lib_directory = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .global_cache_root_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--global_cache_root missing path", .{});
                return error.InvalidArgs;
            }
            lint_args.global_cache_root = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .rule_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--rule missing rule name", .{});
                return error.InvalidArgs;
            }

            const rule_exists: bool = exists: {
                for (available_rules) |available_rule| {
                    if (std.mem.eql(u8, available_rule.rule_id, args[index])) break :exists true;
                }
                break :exists false;
            };
            if (!rule_exists) {
                output.process_printer.println(.err, "rule '{s}' not found", .{args[index]});
                return error.InvalidArgs;
            }

            try rules.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.rule_arg else State.parsing;
        },
        .include_path_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--include arg missing paths", .{});
                return error.InvalidArgs;
            }
            try include_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.include_path_arg else State.parsing;
        },
        .exclude_path_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--exclude arg missing paths", .{});
                return error.InvalidArgs;
            }
            try exclude_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.exclude_path_arg else State.parsing;
        },
        .build_exclude_path_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--build-exclude arg missing paths", .{});
                return error.InvalidArgs;
            }
            try build_exclude_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.build_exclude_path_arg else State.parsing;
        },
        .build_include_path_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--build-include arg missing paths", .{});
                return error.InvalidArgs;
            }
            try build_include_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.build_include_path_arg else State.parsing;
        },
        .filter_path_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--filter arg missing paths", .{});
                return error.InvalidArgs;
            }
            try filter_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.filter_path_arg else State.parsing;
        },
        .format_arg => {
            index += 1;
            if (index == args.len) {
                output.process_printer.println(.err, "--format missing value", .{});
                return error.InvalidArgs;
            }
            inline for (std.meta.fields(@FieldType(Args, "format"))) |field| {
                if (std.mem.eql(u8, args[index], field.name)) {
                    lint_args.format = @enumFromInt(field.value);
                    continue :state State.parsing;
                }
            }
            output.process_printer.println(.err, "--format only supports: {s}", .{comptime formats: {
                var formats: []u8 = "";
                for (std.meta.fieldNames(@FieldType(Args, "format"))) |name| {
                    formats = @constCast(formats ++ name ++ " ");
                }
                break :formats formats;
            }});
            return error.InvalidArgs;
        },
        .fix_arg => {
            lint_args.fix = true;
            continue :state State.parsing;
        },
        .verbose_arg => {
            lint_args.verbose = true;
            continue :state State.parsing;
        },
        .unknown_arg => {
            try unknown_args.append(allocator, try allocator.dupe(u8, arg));
            continue :state State.parsing;
        },
    }

    if (unknown_args.items.len > 0) {
        lint_args.unknown_args = try unknown_args.toOwnedSlice(allocator);
    }
    if (filter_paths.items.len > 0) {
        lint_args.filter_paths = try filter_paths.toOwnedSlice(allocator);
    }
    if (include_paths.items.len > 0) {
        lint_args.include_paths = try include_paths.toOwnedSlice(allocator);
    }
    if (exclude_paths.items.len > 0) {
        lint_args.exclude_paths = try exclude_paths.toOwnedSlice(allocator);
    }
    if (build_include_paths.items.len > 0) {
        lint_args.build_include_paths = try build_include_paths.toOwnedSlice(allocator);
    }
    if (build_exclude_paths.items.len > 0) {
        lint_args.build_exclude_paths = try build_exclude_paths.toOwnedSlice(allocator);
    }
    if (rules.items.len > 0) {
        lint_args.rules = try rules.toOwnedSlice(allocator);
    }

    return lint_args;
}

fn notArgKey(arg: []const u8) bool {
    return arg.len > 0 and arg[0] != '-';
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
        .include_paths = null,
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
        .include_paths = null,
        .unknown_args = null,
    }, args);
}

test "allocParse with verbose arg" {
    const args = try allocParse(
        testing.cliArgs(&.{"--verbose"}),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .verbose = true,
        .include_paths = null,
        .unknown_args = null,
    }, args);
}

test "allocParse with fix arg and files" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--include", "a/b.zig", "--include", "./c.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
        .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
        .unknown_args = null,
    }, args);
}

test "allocParse with duplicate files files" {
    inline for (&.{
        &.{ "--include", "a/b.zig", "--include", "a/b.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "a/b.zig", "--include", "another.zig" },
        &.{ "--include", "a/b.zig", "a/b.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "--include", "a/b.zig", "--include", "another.zig" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "a/b.zig", "another.zig" }),
            .unknown_args = null,
        }, args);
    }
}

test "allocParse with files" {
    inline for (&.{
        &.{ "--include", "a/b.zig", "--include", "./c.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "./c.zig", "--include", "another.zig" },
        &.{ "--include", "a/b.zig", "./c.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "--include", "./c.zig", "--include", "another.zig" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "another.zig" }),
            .unknown_args = null,
        }, args);
    }
}

test "allocParse with exclude files" {
    inline for (&.{
        &.{ "--exclude", "a/b.zig", "--exclude", "./c.zig", "another.zig" },
        &.{ "--exclude", "a/b.zig", "./c.zig", "--exclude", "another.zig" },
        &.{ "--exclude", "a/b.zig", "./c.zig", "another.zig" },
        &.{ "--exclude", "a/b.zig", "--exclude", "./c.zig", "--exclude", "another.zig" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "another.zig" }),
            .unknown_args = null,
        }, args);
    }
}

test "allocParse with filter files" {
    inline for (&.{
        &.{ "--filter", "a/b.zig", "--filter", "./c.zig", "d.zig" },
        &.{ "--filter", "a/b.zig", "./c.zig", "--filter", "d.zig" },
        &.{ "--filter", "a/b.zig", "./c.zig", "d.zig" },
        &.{ "--filter", "a/b.zig", "--filter", "./c.zig", "--filter", "d.zig" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .filter_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
            .unknown_args = null,
        }, args);
    }
}

test "allocParse with build-exclude files" {
    inline for (&.{
        &.{ "--build-exclude", "a/b.zig", "--build-exclude", "./c.zig", "d.zig" },
        &.{ "--build-exclude", "a/b.zig", "./c.zig", "--build-exclude", "d.zig" },
        &.{ "--build-exclude", "a/b.zig", "./c.zig", "d.zig" },
        &.{ "--build-exclude", "a/b.zig", "--build-exclude", "./c.zig", "--build-exclude", "d.zig" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .build_exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
            .unknown_args = null,
        }, args);
    }
}

test "allocParse with build-include files" {
    inline for (&.{
        &.{ "--build-include", "a/b.zig", "--build-include", "./c.zig", "d.zig" },
        &.{ "--build-include", "a/b.zig", "./c.zig", "--build-include", "d.zig" },
        &.{ "--build-include", "a/b.zig", "./c.zig", "d.zig" },
        &.{ "--build-include", "a/b.zig", "--build-include", "./c.zig", "--build-include", "d.zig" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .build_include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
            .unknown_args = null,
        }, args);
    }
}

test "allocParse with exclude and include files" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--exclude", "a/b.zig", "--include", "./c.zig", "--exclude", "d.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "d.zig" }),
        .include_paths = @constCast(&[_][]const u8{"./c.zig"}),
        .unknown_args = null,
    }, args);
}

test "allocParse with all combinations" {
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--unknown", "--include", "a/b.zig", "--include", "./c.zig" }),
        &.{},
        std.testing.allocator,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
        .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
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
    inline for (&.{
        &.{ "--rule", "my_rule_a", "my_rule_b" },
        &.{ "--rule", "my_rule_a", "--rule", "my_rule_b" },
    }) |raw_args| {
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{ .{
                .rule_id = "my_rule_a",
                .run = undefined,
            }, .{
                .rule_id = "my_rule_b",
                .run = undefined,
            } },
            std.testing.allocator,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .rules = @constCast(&[_][]const u8{ "my_rule_a", "my_rule_b" }),
        }, args);
    }
}

test "allocParse with invalid rule arg" {
    var stderr_sink = try output.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{ "--rule", "not_found_rule" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
    ));

    try std.testing.expectEqualStrings("rule 'not_found_rule' not found\n", stderr_sink.output());
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
const output = @import("./output.zig");
