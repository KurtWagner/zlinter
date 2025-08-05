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

/// Contains rule id to path names for overriding the build time config for
/// a rule. This is typically just useful for internal testing.
rule_config_overrides: ?*std.BufMap = null,

build_info: BuildInfo = .default,

/// Whether user has passed in the `--help` flag.
help: bool = false,

/// When using `--fix` repeat the this many passes of the code until there's
/// no more fixes being applied.
fix_passes: u8 = default_fix_passes,

const default_fix_passes = 20;

pub fn deinit(self: Args, allocator: std.mem.Allocator) void {
    if (self.zig_exe) |zig_exe|
        allocator.free(zig_exe);

    if (self.global_cache_root) |global_cache_root|
        allocator.free(global_cache_root);

    if (self.zig_lib_directory) |zig_lib_directory|
        allocator.free(zig_lib_directory);

    if (self.rule_config_overrides) |rule_config_overrides| {
        rule_config_overrides.deinit();
        allocator.destroy(rule_config_overrides);
    }

    inline for (&.{
        "exclude_paths",
        "include_paths",
        "filter_paths",
        "unknown_args",
        "rules",
    }) |field_name| {
        if (@field(self, field_name)) |v| {
            for (v) |s| allocator.free(s);
            allocator.free(v);
        }
    }

    self.build_info.deinit(allocator);
}

pub fn allocParse(
    args: [][:0]u8,
    available_rules: []const LintRule,
    allocator: std.mem.Allocator,
    stdin_reader: anytype,
) error{ OutOfMemory, InvalidArgs }!Args {
    var index: usize = 0;

    var lint_args = Args{};
    errdefer lint_args.deinit(allocator);

    var unknown_args = std.ArrayListUnmanaged([]const u8).empty;
    defer unknown_args.deinit(allocator);

    var include_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer include_paths.deinit(allocator);
    errdefer for (include_paths.items) |p| allocator.free(p);

    var exclude_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer exclude_paths.deinit(allocator);
    errdefer for (exclude_paths.items) |p| allocator.free(p);

    var filter_paths = std.ArrayListUnmanaged([]const u8).empty;
    defer filter_paths.deinit(allocator);
    errdefer for (filter_paths.items) |p| allocator.free(p);

    var rules = std.ArrayListUnmanaged([]const u8).empty;
    defer rules.deinit(allocator);
    errdefer for (rules.items) |r| allocator.free(r);

    const rule_config_overrides = try allocator.create(std.BufMap);
    rule_config_overrides.* = std.BufMap.init(allocator);
    errdefer {
        rule_config_overrides.deinit();
        allocator.destroy(rule_config_overrides);
    }

    var build_info: ?BuildInfo = null;

    const State = enum {
        parsing,
        fix_arg,
        verbose_arg,
        help_arg,
        zig_exe_arg,
        zig_lib_directory_arg,
        global_cache_root_arg,
        unknown_arg,
        format_arg,
        rule_arg,
        filter_path_arg,
        include_path_arg,
        exclude_path_arg,
        rule_config_arg,
        stdin_arg,
        fix_passes_arg,
    };

    const flags: std.StaticStringMap(State) = .initComptime(.{
        .{ "", .parsing },
        .{ "--fix", .fix_arg },
        .{ "--verbose", .verbose_arg },
        .{ "--rule", .rule_arg },
        .{ "--include", .include_path_arg },
        .{ "--exclude", .exclude_path_arg },
        .{ "--filter", .filter_path_arg },
        .{ "--zig_exe", .zig_exe_arg },
        .{ "--zig_lib_directory", .zig_lib_directory_arg },
        .{ "--global_cache_root", .global_cache_root_arg },
        .{ "--format", .format_arg },
        .{ "--rule-config", .rule_config_arg },
        .{ "--stdin", .stdin_arg },
        .{ "--help", .help_arg },
        .{ "-h", .help_arg },
        .{ "--fix-passes", .fix_passes_arg },
    });

    state: switch (State.parsing) {
        .parsing => {
            index += 1; // ignore first arg as this is the binary.
            if (index < args.len)
                continue :state flags.get(args[index]) orelse .unknown_arg;
        },
        .zig_exe_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--zig_exe missing path", .{});
                return error.InvalidArgs;
            }
            lint_args.zig_exe = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .zig_lib_directory_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--zig_lib_directory missing path", .{});
                return error.InvalidArgs;
            }
            lint_args.zig_lib_directory = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .global_cache_root_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--global_cache_root missing path", .{});
                return error.InvalidArgs;
            }
            lint_args.global_cache_root = try allocator.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .rule_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--rule missing rule name", .{});
                return error.InvalidArgs;
            }

            const rule_exists: bool = exists: {
                for (available_rules) |available_rule| {
                    if (std.mem.eql(u8, available_rule.rule_id, args[index])) break :exists true;
                }
                break :exists false;
            };
            if (!rule_exists) {
                rendering.process_printer.println(.err, "rule '{s}' not found", .{args[index]});
                return error.InvalidArgs;
            }

            try rules.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.rule_arg else State.parsing;
        },
        .include_path_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--include arg missing paths", .{});
                return error.InvalidArgs;
            }
            try include_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.include_path_arg else State.parsing;
        },
        .exclude_path_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--exclude arg missing paths", .{});
                return error.InvalidArgs;
            }
            try exclude_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.exclude_path_arg else State.parsing;
        },
        .filter_path_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--filter arg missing paths", .{});
                return error.InvalidArgs;
            }
            try filter_paths.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.filter_path_arg else State.parsing;
        },
        .format_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--format missing value", .{});
                return error.InvalidArgs;
            }
            inline for (std.meta.fields(@FieldType(Args, "format"))) |field| {
                if (std.mem.eql(u8, args[index], field.name)) {
                    lint_args.format = @enumFromInt(field.value);
                    continue :state State.parsing;
                }
            }
            rendering.process_printer.println(.err, "--format only supports: {s}", .{comptime formats: {
                var formats: []u8 = "";
                for (std.meta.fieldNames(@FieldType(Args, "format"))) |name| {
                    formats = @constCast(formats ++ name ++ " ");
                }
                break :formats formats;
            }});
            return error.InvalidArgs;
        },
        .fix_passes_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--fix-passes missing value", .{});
                return error.InvalidArgs;
            }

            const error_message = "--fix-passes expects an int between 1 and 255";
            lint_args.fix_passes = std.fmt.parseInt(u8, args[index], 10) catch {
                rendering.process_printer.println(.err, error_message, .{});
                return error.InvalidArgs;
            };
            if (lint_args.fix_passes == 0) {
                rendering.process_printer.println(.err, error_message, .{});
                return error.InvalidArgs;
            }

            continue :state State.parsing;
        },
        .fix_arg => {
            lint_args.fix = true;
            continue :state State.parsing;
        },
        .verbose_arg => {
            lint_args.verbose = true;
            continue :state State.parsing;
        },
        .help_arg => {
            lint_args.help = true;
            continue :state State.parsing;
        },
        .stdin_arg => {
            build_info = try BuildInfo.consumeStdinAlloc(
                stdin_reader,
                allocator,
                rendering.process_printer,
            ) orelse {
                rendering.process_printer.println(.err, "--stdin but no stdin found", .{});
                return error.InvalidArgs;
            };
            continue :state State.parsing;
        },
        .unknown_arg => {
            try unknown_args.append(allocator, try allocator.dupe(u8, args[index]));
            continue :state State.parsing;
        },
        .rule_config_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--rule-config arg missing rule id", .{});
                return error.InvalidArgs;
            }
            const rule_id = args[index];

            const rule_exists: bool = exists: {
                for (available_rules) |available_rule| {
                    if (std.mem.eql(u8, available_rule.rule_id, args[index])) break :exists true;
                }
                break :exists false;
            };
            if (!rule_exists) {
                rendering.process_printer.println(.err, "rule '{s}' not found", .{args[index]});
                return error.InvalidArgs;
            }

            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--rule-config arg missing zon file path", .{});
                return error.InvalidArgs;
            }
            const zon_file_path = args[index];

            if (rule_config_overrides.get(rule_id) != null) {
                rendering.process_printer.println(.err, "--rule-config rule id '{s}' already set", .{rule_id});
                return error.InvalidArgs;
            }
            try rule_config_overrides.put(rule_id, zon_file_path);
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
    if (rules.items.len > 0) {
        lint_args.rules = try rules.toOwnedSlice(allocator);
    }
    if (rule_config_overrides.count() > 0) {
        lint_args.rule_config_overrides = rule_config_overrides;
    } else {
        rule_config_overrides.deinit();
        allocator.destroy(rule_config_overrides);
    }

    if (build_info) |i| lint_args.build_info = i;

    return lint_args;
}

pub fn printHelp(printer: *rendering.Printer) void {
    const flags: []const struct { []const u8, []const u8 } = &.{
        .{ "-h, --help", "Show help text" },
        .{ "--verbose", "Print extra linting information" },
        .{ "--rule", "Run only the specified rules" },
        .{ "--include", "Only lint these paths, ignoring build.zig includes/excludes" },
        .{ "--exclude", "Skip linting for these paths" },
        .{ "--filter", "Limit linting to the specified resolved paths" },
        .{ "--fix", "Automatically fix some issues (only use with source control)" },
        .{ "--fix-passes", std.fmt.comptimePrint("Repeat fix this many times or until no more fixes are applied (Default {d})", .{default_fix_passes}) },
    };

    comptime var width: usize = 0;
    inline for (0..flags.len) |i| width = @max(flags[i][0].len, width);

    printer.print(.out, "{s}Usage:{s} ", .{ printer.tty.ansiOrEmpty(&.{ .underline, .bold }), printer.tty.ansiOrEmpty(&.{.reset}) });
    printer.print(.out, "zig build <lint step> -- [--include <path>...] [--exclude <path>...] [--filter <path>...] [--rule <name>...] [--fix]\n\n", .{});
    printer.print(.out, "{s}Options:{s}\n", .{ printer.tty.ansiOrEmpty(&.{ .underline, .bold }), printer.tty.ansiOrEmpty(&.{.reset}) });
    for (flags) |tuple| {
        printer.print(
            .out,
            "  {s}{s: <" ++ std.fmt.comptimePrint("{d}", .{width + 2}) ++ "}{s}{s}\n",
            .{
                printer.tty.ansiOrEmpty(&.{.yellow}),
                tuple[0],
                printer.tty.ansiOrEmpty(&.{.reset}),
                tuple[1],
            },
        );
    }
}

fn notArgKey(arg: []const u8) bool {
    return arg.len > 0 and arg[0] != '-';
}

test "allocParse with unknown args" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "-", "-fix", "--a" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .unknown_args = @constCast(&[_][]const u8{ "-", "-fix", "--a" }),
    }, args);
}

test "allocParse with fix arg" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{"--fix"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
    }, args);
}

test "allocParse with verbose arg" {
    var stdin_fbs = std.io.fixedBufferStream("");

    const args = try allocParse(
        testing.cliArgs(&.{"--verbose"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .verbose = true,
    }, args);
}

test "allocParse with help arg" {
    var stdin_fbs = std.io.fixedBufferStream("");

    const args = try allocParse(
        testing.cliArgs(&.{"--help"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .help = true,
    }, args);
}

test "allocParse with fix arg and files" {
    var stdin_fbs = std.io.fixedBufferStream("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--include", "a/b.zig", "--include", "./c.zig" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = true,
        .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
    }, args);
}

test "allocParse with duplicate files files" {
    inline for (&.{
        &.{ "--include", "a/b.zig", "--include", "a/b.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "a/b.zig", "--include", "another.zig" },
        &.{ "--include", "a/b.zig", "a/b.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "--include", "a/b.zig", "--include", "another.zig" },
    }) |raw_args| {
        var stdin_fbs = std.io.fixedBufferStream("");

        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            stdin_fbs.reader(),
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "a/b.zig", "another.zig" }),
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
        var stdin_fbs = std.io.fixedBufferStream("");
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            stdin_fbs.reader(),
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "another.zig" }),
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
        var stdin_fbs = std.io.fixedBufferStream("");
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            stdin_fbs.reader(),
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "another.zig" }),
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
        var stdin_fbs = std.io.fixedBufferStream("");
        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            stdin_fbs.reader(),
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .fix = false,
            .filter_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        }, args);
    }
}

test "allocParse with only exclude_paths" {
    const bytes =
        \\.{
        \\  .exclude_paths = .{"a/b.zig", "./c.zig", "d.zig"},
        \\}
    ;

    var backing = std.ArrayList(u8).init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer().writeInt(usize, bytes.len, .little);
    try backing.writer().writeAll(bytes);

    var stdin_fbs = std.io.fixedBufferStream(backing.items);
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .build_info = .{
            .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        },
    }, args);
}

test "allocParse with only include_paths" {
    const bytes =
        \\.{
        \\  .include_paths = .{"a/b.zig", "./c.zig", "d.zig"},
        \\}
    ;

    var backing = std.ArrayList(u8).init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer().writeInt(usize, bytes.len, .little);
    try backing.writer().writeAll(bytes);

    var stdin_fbs = std.io.fixedBufferStream(backing.items);
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .build_info = .{
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        },
    }, args);
}

test "allocParse with include_paths and exclude_paths" {
    const bytes =
        \\.{
        \\  .exclude_paths = .{"d.zig"},
        \\  .include_paths = .{"a/b.zig", "./c.zig"},
        \\}
    ;

    var backing = std.ArrayList(u8).init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer().writeInt(usize, bytes.len, .little);
    try backing.writer().writeAll(bytes);

    var stdin_fbs = std.io.fixedBufferStream(backing.items);
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .build_info = .{
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
            .exclude_paths = @constCast(&[_][]const u8{"d.zig"}),
        },
    }, args);
}

test "allocParse with exclude and include files" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--exclude", "a/b.zig", "--include", "./c.zig", "--exclude", "d.zig" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix = false,
        .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "d.zig" }),
        .include_paths = @constCast(&[_][]const u8{"./c.zig"}),
    }, args);
}

test "allocParse with all combinations" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--unknown", "--include", "a/b.zig", "--include", "./c.zig" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
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
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--zig_exe", "/some/path here/zig" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .zig_exe = "/some/path here/zig",
    }, args);
}

test "allocParse with global_cache_root arg" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--global_cache_root", "/some/path here/cache" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .global_cache_root = "/some/path here/cache",
    }, args);
}

test "allocParse with zig_lib_directory arg" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--zig_lib_directory", "/some/path here/lib" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .zig_lib_directory = "/some/path here/lib",
    }, args);
}

test "allocParse with format arg" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--format", "default" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .format = .default,
    }, args);
}

test "allocParse with min fix passes arg" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix-passes", "1" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix_passes = 1,
    }, args);
}

test "allocParse with max fix passes arg" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{ "--fix-passes", "255" }),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(Args{
        .fix_passes = 255,
    }, args);
}

test "allocParse with fix passes missing arg" {
    var stdin_fbs = std.io.fixedBufferStream("");

    var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{"--fix-passes"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    ));

    try std.testing.expectEqualStrings("--fix-passes missing value\n", stderr_sink.output());
}

test "allocParse with invalid fix passes arg" {
    inline for (&.{ "-1", "256", "a" }) |arg| {
        var stdin_fbs = std.io.fixedBufferStream("");

        var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
        defer stderr_sink.deinit();

        try std.testing.expectError(error.InvalidArgs, allocParse(
            testing.cliArgs(&.{ "--fix-passes", arg }),
            &.{},
            std.testing.allocator,
            stdin_fbs.reader(),
        ));

        try std.testing.expectEqualStrings("--fix-passes expects an int between 1 and 255\n", stderr_sink.output());
    }
}

test "allocParse with rule arg" {
    inline for (&.{
        &.{ "--rule", "my_rule_a", "my_rule_b" },
        &.{ "--rule", "my_rule_a", "--rule", "my_rule_b" },
    }) |raw_args| {
        var stdin_fbs = std.io.fixedBufferStream("");
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
            stdin_fbs.reader(),
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(Args{
            .rules = @constCast(&[_][]const u8{ "my_rule_a", "my_rule_b" }),
        }, args);
    }
}

test "allocParse with invalid rule arg" {
    var stdin_fbs = std.io.fixedBufferStream("");

    var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{ "--rule", "not_found_rule" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
        stdin_fbs.reader(),
    ));

    try std.testing.expectEqualStrings("rule 'not_found_rule' not found\n", stderr_sink.output());
}

test "allocParse without args" {
    var stdin_fbs = std.io.fixedBufferStream("");
    const args = try allocParse(
        testing.cliArgs(&.{}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
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

        var stdin_fbs = std.io.fixedBufferStream("");

        const args = try allocParse(
            &raw_args,
            &.{},
            std.testing.allocator,
            stdin_fbs.reader(),
        );
        defer args.deinit(std.testing.allocator);
    }
}

test "allocParse with rule_config arg" {
    var stdin_fbs = std.io.fixedBufferStream("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--rule-config", "my_rule", "./path/rule_config.zon" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
        stdin_fbs.reader(),
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, args.rule_config_overrides.?.count());
    try std.testing.expectEqualStrings("./path/rule_config.zon", args.rule_config_overrides.?.get("my_rule").?);
}

test "allocParse with invalid rule config rule id arg" {
    var stdin_fbs = std.io.fixedBufferStream("");

    var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{ "--rule-config", "my_rule", "./path/rule_config.zon" }),
        &.{.{
            .rule_id = "another_rule",
            .run = undefined,
        }},
        std.testing.allocator,
        stdin_fbs.reader(),
    ));

    try std.testing.expectEqualStrings("rule 'my_rule' not found\n", stderr_sink.output());
}

test "allocParse with with missing rule config rule id" {
    var stdin_fbs = std.io.fixedBufferStream("");

    var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{"--rule-config"}),
        &.{},
        std.testing.allocator,
        stdin_fbs.reader(),
    ));

    try std.testing.expectEqualStrings("--rule-config arg missing rule id\n", stderr_sink.output());
}

test "allocParse with with missing rule config rule config path" {
    var stdin_fbs = std.io.fixedBufferStream("");

    var stderr_sink = try rendering.process_printer.attachFakeStderrSink(std.testing.allocator);
    defer stderr_sink.deinit();

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{ "--rule-config", "my_rule" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
        stdin_fbs.reader(),
    ));

    try std.testing.expectEqualStrings("--rule-config arg missing zon file path\n", stderr_sink.output());
}

const testing = struct {
    inline fn cliArgs(args: []const [:0]const u8) [][:0]u8 {
        assertTestOnly();

        var buffer: [args.len + 1][:0]u8 = undefined;
        buffer[0] = @constCast("lint-exe");
        for (0..args.len) |i| buffer[i + 1] = @constCast(args[i]);
        return &buffer;
    }

    inline fn assertTestOnly() void {
        comptime if (!builtin.is_test) @compileError("Test only");
    }
};

const std = @import("std");
const builtin = @import("builtin");
const LintRule = @import("./rules.zig").LintRule;
const rendering = @import("./rendering.zig");
const BuildInfo = @import("BuildInfo.zig");
