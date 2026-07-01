//! Parsed from command line arguments passed to the lint executable.
const Args = @This();

/// Path to the zig executable used to build and run linter - needed for
/// analysing zig standard library.
zig_exe: []const u8,

/// Zig lib path used to build and run linter - needed for analysing zig
/// standard library.
zig_lib_directory: []const u8,

/// Indicates whether to run the linter in fix mode, where it'll attempt to
/// fix any discovered issues instead of reporting them.
fix: bool,

/// If set to true only errors will be reported. Warnings are silently ignored.
///
/// By default, zlinter reports both warnings and errors. In some workflows,
/// you may only want to report errors and ignore warnings — for example, in
/// continuous Integration (CI) pipelines where only correctness issues.
quiet: bool,

/// If set, zlinter will fail (non-zero exit code) if more than the given number
/// of warnings are reported.
max_warnings: ?u32,

/// Only lint or fix (if using the fix argument) the given files. These
/// are owned by the struct and should be freed by calling deinit. This will
/// replace any file resolution provided by the build file.
/// /// This is populated with the `--include <path>` flag.
include_paths: ?[][]const u8,

/// Similar to `files` but will be used to filter out files after resolution.
/// This is populated with the `--filter <path>` flag.
filter_paths: ?[][]const u8,

/// Exclude these from linting irrespective of how the files were resolved.
/// This is populated with the `--exclude <path>` flag.
exclude_paths: ?[][]const u8,

/// The format to print the lint result output in.
format: enum { default },

/// Contains any arguments that were found that unknown. When this happens
/// an error with the help does should be presented to the user as this
/// usually a user error that can be rectified. These are owned by the
/// struct and should be freed by calling deinit.
unknown_args: ?[][]const u8,

/// Will contain rules that should be run. If unset, assume all rules
/// should be run. This can be used to focus a run on a single rule
rules: ?[][]const u8,

/// Whether to write additional information out to stdout.
verbose: bool,

build_info: BuildInfo,

/// Whether user has passed in the `--help` flag.
help: bool,

/// When using `--fix` repeat the this many passes of the code until there's
/// no more fixes being applied.
fix_passes: u8,

const default_fix_passes = 20;

pub fn deinit(self: Args, allocator: std.mem.Allocator) void {
    allocator.free(self.zig_exe);

    allocator.free(self.zig_lib_directory);

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

/// Parses linter command-line arguments.
///
/// The Zig executable and Zig lib directory are required build configuration
/// values. They are normally injected by the build step that runs zlinter, not
/// typed by end users. Missing values indicate a broken zlinter build
/// integration and return `error.InvalidBuildConfig`. Duplicate build
/// configuration values also return `error.InvalidBuildConfig`.
///
/// User-facing argument mistakes, such as missing flag values or unknown rule
/// ids, return `error.InvalidArgs`. Unknown flags are collected in
/// `unknown_args` so callers can print all of them with the help text.
pub fn allocParse(
    args: []const [:0]const u8,
    available_rules: []const LintRule,
    gpa: std.mem.Allocator,
    stdin_reader: *std.Io.Reader,
) error{ OutOfMemory, InvalidArgs, InvalidBuildConfig }!Args {
    var index: usize = 0;

    var zig_exe: ?[]const u8 = null;
    errdefer if (zig_exe) |path| gpa.free(path);

    var zig_lib_directory: ?[]const u8 = null;
    errdefer if (zig_lib_directory) |path| gpa.free(path);

    var fix: bool = false;
    var quiet: bool = false;
    var max_warnings: ?u32 = null;
    var format: @FieldType(Args, "format") = .default;
    var verbose: bool = false;
    var help: bool = false;
    var fix_passes: u8 = default_fix_passes;

    var unknown_args = std.ArrayList([]const u8).empty;
    defer unknown_args.deinit(gpa);
    errdefer for (unknown_args.items) |arg| gpa.free(arg);

    var include_paths = std.ArrayList([]const u8).empty;
    defer include_paths.deinit(gpa);
    errdefer for (include_paths.items) |p| gpa.free(p);

    var exclude_paths = std.ArrayList([]const u8).empty;
    defer exclude_paths.deinit(gpa);
    errdefer for (exclude_paths.items) |p| gpa.free(p);

    var filter_paths = std.ArrayList([]const u8).empty;
    defer filter_paths.deinit(gpa);
    errdefer for (filter_paths.items) |p| gpa.free(p);

    var rules = std.ArrayList([]const u8).empty;
    defer rules.deinit(gpa);
    errdefer for (rules.items) |r| gpa.free(r);

    var build_info: ?BuildInfo = null;

    const State = enum {
        parsing,
        fix_arg,
        quiet_arg,
        verbose_arg,
        help_arg,
        zig_exe_arg,
        zig_lib_directory_arg,
        unknown_arg,
        format_arg,
        rule_arg,
        filter_path_arg,
        include_path_arg,
        exclude_path_arg,
        stdin_arg,
        fix_passes_arg,
        max_warnings_arg,
    };

    const flags: std.StaticStringMap(State) = .initComptime(.{
        .{ "", .parsing },
        .{ "--fix", .fix_arg },
        .{ "--quiet", .quiet_arg },
        .{ "--verbose", .verbose_arg },
        .{ "--rule", .rule_arg },
        .{ "--include", .include_path_arg },
        .{ "--exclude", .exclude_path_arg },
        .{ "--filter", .filter_path_arg },
        .{ "--zig_exe", .zig_exe_arg },
        .{ "--zig_lib_directory", .zig_lib_directory_arg },
        .{ "--format", .format_arg },
        .{ "--stdin", .stdin_arg },
        .{ "--help", .help_arg },
        .{ "-h", .help_arg },
        .{ "--fix-passes", .fix_passes_arg },
        .{ "--max-warnings", .max_warnings_arg },
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
            if (zig_exe != null) {
                rendering.process_printer.println(.err, "zlinter build config duplicate --zig_exe", .{});
                return error.InvalidBuildConfig;
            }
            zig_exe = try gpa.dupe(u8, args[index]);
            continue :state State.parsing;
        },
        .zig_lib_directory_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--zig_lib_directory missing path", .{});
                return error.InvalidArgs;
            }
            if (zig_lib_directory != null) {
                rendering.process_printer.println(.err, "zlinter build config duplicate --zig_lib_directory", .{});
                return error.InvalidBuildConfig;
            }
            zig_lib_directory = try gpa.dupe(u8, args[index]);
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

            try rules.append(gpa, try gpa.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.rule_arg else State.parsing;
        },
        .include_path_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--include arg missing paths", .{});
                return error.InvalidArgs;
            }
            try include_paths.append(gpa, try gpa.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.include_path_arg else State.parsing;
        },
        .exclude_path_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--exclude arg missing paths", .{});
                return error.InvalidArgs;
            }
            try exclude_paths.append(gpa, try gpa.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.exclude_path_arg else State.parsing;
        },
        .filter_path_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--filter arg missing paths", .{});
                return error.InvalidArgs;
            }
            try filter_paths.append(gpa, try gpa.dupe(u8, args[index]));
            continue :state if (index + 1 < args.len and notArgKey(args[index + 1])) State.filter_path_arg else State.parsing;
        },
        .format_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--format missing value", .{});
                return error.InvalidArgs;
            }

            const field_names = comptime std.meta.fieldNames(@FieldType(Args, "format"));
            inline for (field_names, 0..) |field_name, i| {
                if (std.mem.eql(u8, args[index], field_name)) {
                    format = @enumFromInt(i);
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
        .max_warnings_arg => {
            index += 1;

            if (index == args.len) {
                rendering.process_printer.println(.err, "--max-warnings missing value", .{});
                return error.InvalidArgs;
            }

            const error_message = "--max-warnings expects a u32";
            max_warnings = std.fmt.parseInt(u32, args[index], 10) catch {
                rendering.process_printer.println(.err, error_message, .{});
                return error.InvalidArgs;
            };

            continue :state State.parsing;
        },
        .fix_passes_arg => {
            index += 1;
            if (index == args.len) {
                rendering.process_printer.println(.err, "--fix-passes missing value", .{});
                return error.InvalidArgs;
            }

            const error_message = "--fix-passes expects an int between 1 and 255";
            fix_passes = std.fmt.parseInt(u8, args[index], 10) catch {
                rendering.process_printer.println(.err, error_message, .{});
                return error.InvalidArgs;
            };
            if (fix_passes == 0) {
                rendering.process_printer.println(.err, error_message, .{});
                return error.InvalidArgs;
            }

            continue :state State.parsing;
        },
        .fix_arg => {
            fix = true;
            continue :state State.parsing;
        },
        .quiet_arg => {
            quiet = true;
            continue :state State.parsing;
        },
        .verbose_arg => {
            verbose = true;
            continue :state State.parsing;
        },
        .help_arg => {
            help = true;
            continue :state State.parsing;
        },
        .stdin_arg => {
            build_info = try BuildInfo.consumeStdinAlloc(
                stdin_reader,
                gpa,
                rendering.process_printer,
            ) orelse {
                rendering.process_printer.println(.err, "--stdin but no stdin found", .{});
                return error.InvalidArgs;
            };
            continue :state State.parsing;
        },
        .unknown_arg => {
            try unknown_args.append(gpa, try gpa.dupe(u8, args[index]));
            continue :state State.parsing;
        },
    }

    if (zig_exe == null or zig_lib_directory == null) {
        if (zig_exe == null)
            rendering.process_printer.println(.err, "zlinter build config missing --zig_exe", .{});
        if (zig_lib_directory == null)
            rendering.process_printer.println(.err, "zlinter build config missing --zig_lib_directory", .{});
        return error.InvalidBuildConfig;
    }

    return Args{
        .zig_exe = zig_exe.?,
        .zig_lib_directory = zig_lib_directory.?,
        .fix = fix,
        .quiet = quiet,
        .max_warnings = max_warnings,
        .include_paths = if (include_paths.items.len > 0) try include_paths.toOwnedSlice(gpa) else null,
        .filter_paths = if (filter_paths.items.len > 0) try filter_paths.toOwnedSlice(gpa) else null,
        .exclude_paths = if (exclude_paths.items.len > 0) try exclude_paths.toOwnedSlice(gpa) else null,
        .format = format,
        .unknown_args = if (unknown_args.items.len > 0) try unknown_args.toOwnedSlice(gpa) else null,
        .rules = if (rules.items.len > 0) try rules.toOwnedSlice(gpa) else null,
        .verbose = verbose,
        .build_info = build_info orelse .default,
        .help = help,
        .fix_passes = fix_passes,
    };
}

pub fn printHelp(printer: *rendering.Printer) void {
    const flags: []const struct { []const u8, []const u8 } = &.{
        .{ "-h, --help", "Show help text" },
        .{ "--verbose", "Print extra linting information" },
        .{ "--rule", "Run only the specified rules" },
        .{ "--include", "Only lint these paths, ignoring build.zig includes/excludes" },
        .{ "--exclude", "Skip linting for these paths" },
        .{ "--filter", "Limit linting to the specified resolved paths" },
        .{ "--quiet", "Only report errors (not warnings)" },
        .{ "--max-warnings", "Fail if there are more than this number of warnings" },
        .{ "--fix", "Automatically fix some issues (only use with source control)" },
        .{ "--fix-passes", std.fmt.comptimePrint("Repeat fix this many times or until no more fixes are applied (Default {d})", .{default_fix_passes}) },
    };

    comptime var width: usize = 0;
    inline for (0..flags.len) |i| width = @max(flags[i][0].len, width);

    printer.print(.out, "{s}Usage:{s} ", .{ printer.tty.ansiOrEmpty(&.{ .underline, .bold }), printer.tty.ansiOrEmpty(&.{.reset}) });
    printer.print(.out, "zig build <lint step> -- [--include <path>...] [--exclude <path>...] [--filter <path>...] [--rule <name>...] [--fix] [--quiet] [--max-warnings <u32>]\n\n", .{});
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
    printer.flush() catch @panic("Failed to flush help docs");
}

fn notArgKey(arg: []const u8) bool {
    return arg.len > 0 and arg[0] != '-';
}

test "allocParse with unknown args" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "-", "-fix", "--a" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .unknown_args = @constCast(&[_][]const u8{ "-", "-fix", "--a" }),
    }), args);
}

test "allocParse with fix arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{"--fix"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .fix = true,
    }), args);
}

test "allocParse with quiet arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{"--quiet"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .quiet = true,
    }), args);
}

test "allocParse with verbose arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{"--verbose"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .verbose = true,
    }), args);
}

test "allocParse with help arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{"--help"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .help = true,
    }), args);
}

test "allocParse with fix arg and files" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--include", "a/b.zig", "--include", "./c.zig" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .fix = true,
        .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
    }), args);
}

test "allocParse with duplicate files files" {
    inline for (&.{
        &.{ "--include", "a/b.zig", "--include", "a/b.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "a/b.zig", "--include", "another.zig" },
        &.{ "--include", "a/b.zig", "a/b.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "--include", "a/b.zig", "--include", "another.zig" },
    }) |raw_args| {
        var stdin_fbs = std.Io.Reader.fixed("");

        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(testing.expected(.{
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "a/b.zig", "another.zig" }),
        }), args);
    }
}

test "allocParse with files" {
    inline for (&.{
        &.{ "--include", "a/b.zig", "--include", "./c.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "./c.zig", "--include", "another.zig" },
        &.{ "--include", "a/b.zig", "./c.zig", "another.zig" },
        &.{ "--include", "a/b.zig", "--include", "./c.zig", "--include", "another.zig" },
    }) |raw_args| {
        var stdin_fbs = std.Io.Reader.fixed("");

        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(testing.expected(.{
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "another.zig" }),
        }), args);
    }
}

test "allocParse with exclude files" {
    inline for (&.{
        &.{ "--exclude", "a/b.zig", "--exclude", "./c.zig", "another.zig" },
        &.{ "--exclude", "a/b.zig", "./c.zig", "--exclude", "another.zig" },
        &.{ "--exclude", "a/b.zig", "./c.zig", "another.zig" },
        &.{ "--exclude", "a/b.zig", "--exclude", "./c.zig", "--exclude", "another.zig" },
    }) |raw_args| {
        var stdin_fbs = std.Io.Reader.fixed("");

        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(testing.expected(.{
            .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "another.zig" }),
        }), args);
    }
}

test "allocParse with filter files" {
    inline for (&.{
        &.{ "--filter", "a/b.zig", "--filter", "./c.zig", "d.zig" },
        &.{ "--filter", "a/b.zig", "./c.zig", "--filter", "d.zig" },
        &.{ "--filter", "a/b.zig", "./c.zig", "d.zig" },
        &.{ "--filter", "a/b.zig", "--filter", "./c.zig", "--filter", "d.zig" },
    }) |raw_args| {
        var stdin_fbs = std.Io.Reader.fixed("");

        const args = try allocParse(
            testing.cliArgs(raw_args),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(testing.expected(.{
            .filter_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        }), args);
    }
}

test "allocParse with only exclude_paths" {
    const bytes =
        \\.{
        \\  .exclude_paths = .{"a/b.zig", "./c.zig", "d.zig"},
        \\}
    ;

    var backing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer.writeInt(u32, @intCast(bytes.len), .little);
    try backing.writer.writeAll(bytes);

    var stdin_fbs = std.Io.Reader.fixed(backing.written());
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .build_info = BuildInfo{
            .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        },
    }), args);
}

test "allocParse with only include_paths" {
    const bytes =
        \\.{
        \\  .include_paths = .{"a/b.zig", "./c.zig", "d.zig"},
        \\}
    ;

    var backing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer.writeInt(u32, @intCast(bytes.len), .little);
    try backing.writer.writeAll(bytes);

    var stdin_fbs = std.Io.Reader.fixed(backing.written());
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .build_info = BuildInfo{
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig", "d.zig" }),
        },
    }), args);
}

test "allocParse with include_paths and exclude_paths" {
    const bytes =
        \\.{
        \\  .exclude_paths = .{"d.zig"},
        \\  .include_paths = .{"a/b.zig", "./c.zig"},
        \\}
    ;

    var backing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer.writeInt(u32, @intCast(bytes.len), .little);
    try backing.writer.writeAll(bytes);

    var stdin_fbs = std.Io.Reader.fixed(backing.written());
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .build_info = BuildInfo{
            .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
            .exclude_paths = @constCast(&[_][]const u8{"d.zig"}),
        },
    }), args);
}

test "allocParse with compile_unit_names" {
    const bytes =
        \\.{
        \\  .compile_unit_names = .{"my_app", "my_lib_tests"},
        \\}
    ;

    var backing: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer backing.deinit();

    try backing.writer.writeInt(u32, @intCast(bytes.len), .little);
    try backing.writer.writeAll(bytes);

    var stdin_fbs = std.Io.Reader.fixed(backing.written());
    const args = try allocParse(
        testing.cliArgs(&.{"--stdin"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .build_info = BuildInfo{
            .compile_unit_names = @constCast(&[_][]const u8{ "my_app", "my_lib_tests" }),
        },
    }), args);
}

test "allocParse with exclude and include files" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--exclude", "a/b.zig", "--include", "./c.zig", "--exclude", "d.zig" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .exclude_paths = @constCast(&[_][]const u8{ "a/b.zig", "d.zig" }),
        .include_paths = @constCast(&[_][]const u8{"./c.zig"}),
    }), args);
}

test "allocParse with all combinations" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--fix", "--unknown", "--include", "a/b.zig", "--include", "./c.zig" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .fix = true,
        .include_paths = @constCast(&[_][]const u8{ "a/b.zig", "./c.zig" }),
        .unknown_args = @constCast(&[_][]const u8{
            "--unknown",
        }),
    }), args);
}

test "allocParse with zig_exe arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgsWithoutBuildConfig(&.{
            "--zig_exe",
            "/some/path here/zig",
            "--zig_lib_directory",
            testing.zig_lib_directory,
        }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .zig_exe = "/some/path here/zig",
    }), args);
}

test "allocParse with zig_lib_directory arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgsWithoutBuildConfig(&.{
            "--zig_exe",
            testing.zig_exe,
            "--zig_lib_directory",
            "/some/path here/lib",
        }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .zig_lib_directory = "/some/path here/lib",
    }), args);
}

test "allocParse with format arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--format", "default" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{}), args);
}

test "allocParse with min fix passes arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--fix-passes", "1" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .fix_passes = 1,
    }), args);
}

test "allocParse with max fix passes arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--fix-passes", "255" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .fix_passes = 255,
    }), args);
}

test "allocParse with fix passes missing arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_sink.deinit();
    rendering.process_printer.stderr = &stderr_sink.writer;

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{"--fix-passes"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    ));

    try std.testing.expectEqualStrings("--fix-passes missing value\n", stderr_sink.written());
}

test "allocParse with invalid fix passes arg" {
    inline for (&.{ "-1", "0", "256", "a" }) |arg| {
        var stdin_fbs = std.Io.Reader.fixed("");

        var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr_sink.deinit();
        rendering.process_printer.stderr = &stderr_sink.writer;

        try std.testing.expectError(error.InvalidArgs, allocParse(
            testing.cliArgs(&.{ "--fix-passes", arg }),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        ));

        try std.testing.expectEqualStrings("--fix-passes expects an int between 1 and 255\n", stderr_sink.written());
    }
}

test "allocParse with rule arg" {
    inline for (&.{
        &.{ "--rule", "my_rule_a", "my_rule_b" },
        &.{ "--rule", "my_rule_a", "--rule", "my_rule_b" },
    }) |raw_args| {
        var stdin_fbs = std.Io.Reader.fixed("");

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
            &stdin_fbs,
        );
        defer args.deinit(std.testing.allocator);

        try std.testing.expectEqualDeep(testing.expected(.{
            .rules = @constCast(&[_][]const u8{ "my_rule_a", "my_rule_b" }),
        }), args);
    }
}

test "allocParse with invalid rule arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_sink.deinit();
    rendering.process_printer.stderr = &stderr_sink.writer;

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{ "--rule", "not_found_rule" }),
        &.{.{
            .rule_id = "my_rule",
            .run = undefined,
        }},
        std.testing.allocator,
        &stdin_fbs,
    ));

    try std.testing.expectEqualStrings("rule 'not_found_rule' not found\n", stderr_sink.written());
}

test "allocParse without args" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{}), args);
}

test "allocParse without build config" {
    var stdin_fbs = std.Io.Reader.fixed("");

    var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_sink.deinit();
    rendering.process_printer.stderr = &stderr_sink.writer;

    try std.testing.expectError(error.InvalidBuildConfig, allocParse(
        testing.cliArgsWithoutBuildConfig(&.{}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    ));

    try std.testing.expectEqualStrings(
        "zlinter build config missing --zig_exe\nzlinter build config missing --zig_lib_directory\n",
        stderr_sink.written(),
    );
}

test "allocParse with duplicate build config" {
    inline for (&.{
        .{
            .args = &.{ "--zig_exe", "/other/zig" },
            .message = "zlinter build config duplicate --zig_exe\n",
        },
        .{
            .args = &.{ "--zig_lib_directory", "/other/lib" },
            .message = "zlinter build config duplicate --zig_lib_directory\n",
        },
    }) |case| {
        var stdin_fbs = std.Io.Reader.fixed("");

        var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr_sink.deinit();
        rendering.process_printer.stderr = &stderr_sink.writer;

        try std.testing.expectError(error.InvalidBuildConfig, allocParse(
            testing.cliArgs(case.args),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        ));

        try std.testing.expectEqualStrings(case.message, stderr_sink.written());
    }
}

test "allocParse fuzz" {
    var seed: u64 = undefined;
    std.testing.io.random(std.mem.asBytes(&seed));

    const max_args = 10;

    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    var buffer: [1024]u8 = undefined;
    var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_sink.deinit();
    rendering.process_printer.stderr = &stderr_sink.writer;

    var mem: [(buffer.len + 1) * max_args]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    for (0..1000) |_| {
        defer fba.reset();

        var raw_args: [max_args][:0]u8 = undefined;
        for (0..raw_args.len) |i| {
            rand.bytes(&buffer);
            raw_args[i] = try fba.allocator().dupeSentinel(u8, buffer[0..], 0);
        }

        var stdin_fbs = std.Io.Reader.fixed("");

        const args = allocParse(
            &raw_args,
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        ) catch |err| switch (err) {
            error.InvalidArgs,
            error.InvalidBuildConfig,
            => continue,
            error.OutOfMemory => return err,
        };
        defer args.deinit(std.testing.allocator);
    }
}

test "allocParse with min --max-warnings arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--max-warnings", "0" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .max_warnings = 0,
    }), args);
}

test "allocParse with max --max-warnings arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    const args = try allocParse(
        testing.cliArgs(&.{ "--max-warnings", "4294967295" }),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    );
    defer args.deinit(std.testing.allocator);

    try std.testing.expectEqualDeep(testing.expected(.{
        .max_warnings = 4294967295,
    }), args);
}

test "allocParse with fix --max-warnings arg" {
    var stdin_fbs = std.Io.Reader.fixed("");

    var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr_sink.deinit();
    rendering.process_printer.stderr = &stderr_sink.writer;

    try std.testing.expectError(error.InvalidArgs, allocParse(
        testing.cliArgs(&.{"--max-warnings"}),
        &.{},
        std.testing.allocator,
        &stdin_fbs,
    ));

    try std.testing.expectEqualStrings("--max-warnings missing value\n", stderr_sink.written());
}

test "allocParse with invalid --max-warnings arg" {
    inline for (&.{ "-1", "4294967296", "a" }) |arg| {
        var stdin_fbs = std.Io.Reader.fixed("");

        var stderr_sink: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer stderr_sink.deinit();
        rendering.process_printer.stderr = &stderr_sink.writer;

        try std.testing.expectError(error.InvalidArgs, allocParse(
            testing.cliArgs(&.{ "--max-warnings", arg }),
            &.{},
            std.testing.allocator,
            &stdin_fbs,
        ));

        try std.testing.expectEqualStrings("--max-warnings expects a u32\n", stderr_sink.written());
    }
}

const testing = struct {
    const zig_exe = "/test/zig";
    const zig_lib_directory = "/test/zig/lib";

    var buffer: [64][:0]u8 = undefined;

    inline fn cliArgs(comptime args: []const [:0]const u8) [][:0]u8 {
        assertTestOnly();

        buffer[0] = @constCast("lint-exe");
        buffer[1] = @constCast("--zig_exe");
        buffer[2] = @constCast(zig_exe);
        buffer[3] = @constCast("--zig_lib_directory");
        buffer[4] = @constCast(zig_lib_directory);
        inline for (0..args.len) |i| buffer[i + 5] = @constCast(args[i]);
        return buffer[0 .. args.len + 5];
    }

    inline fn cliArgsWithoutBuildConfig(comptime args: []const [:0]const u8) [][:0]u8 {
        assertTestOnly();

        buffer[0] = @constCast("lint-exe");
        inline for (0..args.len) |i| buffer[i + 1] = @constCast(args[i]);
        return buffer[0 .. args.len + 1];
    }

    inline fn expected(comptime overrides: anytype) Args {
        assertTestOnly();

        var result = Args{
            .zig_exe = zig_exe,
            .zig_lib_directory = zig_lib_directory,
            .fix = false,
            .quiet = false,
            .max_warnings = null,
            .include_paths = null,
            .filter_paths = null,
            .exclude_paths = null,
            .format = .default,
            .unknown_args = null,
            .rules = null,
            .verbose = false,
            .build_info = .default,
            .help = false,
            .fix_passes = default_fix_passes,
        };
        inline for (comptime std.meta.fieldNames(@TypeOf(overrides))) |field_name| {
            @field(result, field_name) = @field(overrides, field_name);
        }
        return result;
    }

    inline fn assertTestOnly() void {
        comptime if (!builtin.is_test) @compileError("Test only");
    }
};

const builtin = @import("builtin");
const std = @import("std");
const LintRule = @import("./rules.zig").LintRule;
const BuildInfo = @import("BuildInfo.zig");
const rendering = @import("./rendering.zig");

test {
    std.testing.refAllDecls(@This());
}
