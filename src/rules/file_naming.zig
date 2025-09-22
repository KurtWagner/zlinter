//! Enforces a consistent naming convention for files. For example, `TitleCase`
//! for implicit structs and `snake_case` for namespaces.

/// Config for file_naming rule.
pub const Config = struct {
    /// Style and severity for a file that is a namespace (i.e., does not have root container fields)
    file_namespace: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .snake_case,
        .severity = .@"error",
    },

    /// Style and severity for a file that is a struct (i.e., has root container fields)
    file_struct: zlinter.rules.LintTextStyleWithSeverity = .{
        .style = .title_case,
        .severity = .@"error",
    },
};

/// Builds and returns the file_naming rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.file_naming),
        .run = &run,
    };
}

/// Runs the file_naming rule.
fn run(
    rule: zlinter.rules.LintRule,
    _: *zlinter.session.LintContext,
    doc: *const zlinter.session.LintDocument,
    gpa: std.mem.Allocator,
    options: zlinter.rules.RunOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    const message, const severity = msg: {
        const basename = std.fs.path.basename(doc.path);
        if (shims.isRootImplicitStruct(doc.handle.tree)) {
            if (config.file_struct.severity != .off and !config.file_struct.style.check(basename)) {
                break :msg .{
                    try std.fmt.allocPrint(gpa, "File is struct so name should be {s}", .{config.file_struct.style.name()}),
                    config.file_struct.severity,
                };
            }
        } else if (config.file_namespace.severity != .off and !config.file_namespace.style.check(basename)) {
            break :msg .{
                try std.fmt.allocPrint(gpa, "File is namespace so name should be {s}", .{config.file_namespace.style.name()}),
                config.file_namespace.severity,
            };
        }
        return null;
    };

    var lint_problems = try gpa.alloc(zlinter.results.LintProblem, 1);
    lint_problems[0] = .{
        .severity = severity,
        .rule_id = rule.rule_id,
        .start = .zero,
        .end = .zero,
        .message = message,
    };
    return try zlinter.results.LintResult.init(
        gpa,
        doc.path,
        lint_problems,
    );
}

// ----------------------------------------------------------------------------
// Unit tests
// ----------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "severity" {
    inline for (&.{
        zlinter.rules.LintProblemSeverity.@"error",
        zlinter.rules.LintProblemSeverity.warning,
    }) |severity| {
        // Implicit struct file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ field_a: u32
        ,
            .{ .filename = zlinter.testing.paths.posix("snake_case.zig") },
            Config{
                .file_struct = .{
                    .style = .title_case,
                    .severity = severity,
                },
            },
            &.{.{
                .rule_id = "file_naming",
                .severity = severity,
                .slice = "",
                .message = "File is struct so name should be TitleCase",
            }},
        );

        // namespace struct file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ pub const a = 1;
        ,
            .{ .filename = zlinter.testing.paths.posix("TitleCase.zig") },
            Config{
                .file_namespace = .{
                    .style = .snake_case,
                    .severity = severity,
                },
            },
            &.{.{
                .rule_id = "file_naming",
                .severity = severity,
                .slice = "",
                .message = "File is namespace so name should be snake_case",
            }},
        );
    }
    // Off:
    {
        const severity: zlinter.rules.LintProblemSeverity = .off;

        // Implicit struct file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ field_a: u32
        ,
            .{ .filename = zlinter.testing.paths.posix("snake_case.zig") },
            Config{
                .file_struct = .{
                    .style = .title_case,
                    .severity = severity,
                },
            },
            &.{},
        );

        // namespace struct file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ pub const a = 1;
        ,
            .{ .filename = zlinter.testing.paths.posix("TitleCase.zig") },
            Config{
                .file_namespace = .{
                    .style = .title_case,
                    .severity = severity,
                },
            },
            &.{},
        );
    }
}

test "good cases" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "pub const hit_points: f32 = 1;",
        .{ .filename = zlinter.testing.paths.posix("path/to/my_file.zig") },
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "pub const hit_points: f32 = 1;",
        .{ .filename = zlinter.testing.paths.posix("path/to/file.zig") },
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "hit_points: f32,",
        .{ .filename = zlinter.testing.paths.posix("path/to/File.zig") },
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "hit_points: f32,",
        .{ .filename = zlinter.testing.paths.posix("path/to/MyFile.zig") },
        Config{},
        &.{},
    );
}

test "expects snake_case with TitleCase" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "pub const hit_points: f32 = 1;",
        .{
            .filename = zlinter.testing.paths.posix("path/to/File.zig"),
        },
        Config{},
        &.{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .slice = "",
                .message = "File is namespace so name should be snake_case",
            },
        },
    );
}

test "expects snake_case with camelCase" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "pub const hit_points: f32 = 1;",
        .{
            .filename = zlinter.testing.paths.posix("path/to/myFile.zig"),
        },
        Config{},
        &.{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .slice = "",
                .message = "File is namespace so name should be snake_case",
            },
        },
    );
}

test "expects TitleCase with snake_case" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "hit_points: f32,",
        .{
            .filename = zlinter.testing.paths.posix("path/to/myFile.zig"),
        },
        Config{ .file_struct = .{ .severity = .warning, .style = .title_case } },
        &.{
            .{
                .rule_id = "file_naming",
                .severity = .warning,
                .slice = "",
                .message = "File is struct so name should be TitleCase",
            },
        },
    );
}

test "expects TitleCase with under_score" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "hit_points: f32,",
        .{
            .filename = zlinter.testing.paths.posix("path/to/my_file.zig"),
        },
        Config{},
        &.{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .slice = "",
                .message = "File is struct so name should be TitleCase",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const shims = zlinter.shims;
