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
pub fn buildRule(options: zlinter.rules.LintRuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.file_naming),
        .run = &run,
    };
}

/// Runs the file_naming rule.
fn run(
    rule: zlinter.rules.LintRule,
    ctx: zlinter.session.LintContext,
    doc: zlinter.session.LintDocument,
    allocator: std.mem.Allocator,
    options: zlinter.session.LintOptions,
) error{OutOfMemory}!?zlinter.results.LintResult {
    _ = ctx;
    const config = options.getConfig(Config);

    const error_message: ?[]const u8, const severity: ?zlinter.rules.LintProblemSeverity = msg: {
        const basename = std.fs.path.basename(doc.path);
        if (zlinter.shims.isRootImplicitStruct(doc.handle.tree)) {
            if (!config.file_struct.style.check(basename)) {
                break :msg .{
                    try std.fmt.allocPrint(allocator, "File is struct so name should be {s}", .{config.file_struct.style.name()}),
                    config.file_struct.severity,
                };
            }
        } else if (!config.file_namespace.style.check(basename)) {
            break :msg .{
                try std.fmt.allocPrint(allocator, "File is namespace so name should be {s}", .{config.file_namespace.style.name()}),
                config.file_struct.severity,
            };
        }
        break :msg .{ null, null };
    };

    if (error_message) |message| {
        var lint_problems = try allocator.alloc(zlinter.results.LintProblem, 1);
        lint_problems[0] = .{
            .severity = severity.?,
            .rule_id = rule.rule_id,
            .start = .zero,
            .end = .zero,
            .message = message,
        };
        return try zlinter.results.LintResult.init(
            allocator,
            doc.path,
            lint_problems,
        );
    } else return null;
}

// ----------------------------------------------------------------------------
// Unit tests
// ----------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "good cases" {
    const rule = buildRule(.{});

    {
        var result = try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/my_file.zig"),
            "pub const hit_points: f32 = 1;",
        );
        defer {
            if (result) |*r| r.deinit(std.testing.allocator);
        }
    }
    {
        var result = try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/file.zig"),
            "pub const hit_points: f32 = 1;",
        );
        defer {
            if (result) |*r| r.deinit(std.testing.allocator);
        }
    }
    {
        var result = try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/File.zig"),
            "hit_points: f32,",
        );
        defer {
            if (result) |*r| r.deinit(std.testing.allocator);
        }
    }
    {
        var result = try zlinter.testing.runRule(
            rule,
            zlinter.testing.paths.posix("path/to/MyFile.zig"),
            "hit_points: f32,",
        );
        defer {
            if (result) |*r| r.deinit(std.testing.allocator);
        }
    }
}

test "expects snake_case with TitleCase" {
    const rule = buildRule(.{});

    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/File.zig"),
        "pub const hit_points: f32 = 1;",
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/File.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .message = "File is namespace so name should be snake_case",
            },
        },
        result.problems,
    );
}

test "expects snake_case with camelCase" {
    const rule = buildRule(.{});

    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/myFile.zig"),
        "pub const hit_points: f32 = 1;",
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/myFile.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .message = "File is namespace so name should be snake_case",
            },
        },
        result.problems,
    );
}

test "expects TitleCase with snake_case" {
    const rule = buildRule(.{});

    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/myFile.zig"),
        "hit_points: f32,",
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/myFile.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .message = "File is struct so name should be TitleCase",
            },
        },
        result.problems,
    );
}

test "expects TitleCase with under_score" {
    const rule = buildRule(.{});

    var result = (try zlinter.testing.runRule(
        rule,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
        "hit_points: f32,",
    )).?;
    defer result.deinit(std.testing.allocator);

    try std.testing.expectStringEndsWith(
        result.file_path,
        zlinter.testing.paths.posix("path/to/my_file.zig"),
    );

    try zlinter.testing.expectProblemsEqual(
        &[_]zlinter.results.LintProblem{
            .{
                .rule_id = "file_naming",
                .severity = .@"error",
                .start = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .end = .{
                    .offset = 0,
                    .line = 0,
                    .column = 0,
                },
                .message = "File is struct so name should be TitleCase",
            },
        },
        result.problems,
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
