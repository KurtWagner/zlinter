//! Enforces a consistent naming convention for files. For example, `TitleCase`
//! for implicit structs and `snake_case` for namespaces.

/// Config for file_naming rule.
pub const Config = struct {
    /// Style and severity for a file that is a namespace (i.e., does not have root container fields)
    file_namespace: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .snake_case },

    /// Style and severity for a file that is a struct (i.e., has root container fields)
    file_struct: zlinter.rules.LintTextStyleWithSeverity = .{ .@"error" = .title_case },
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
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);

    // TODO: I worry this pattern will be error prone if configs change often
    // an argument is that unit tests should cover it but from reviewing rules
    // I can see this isnt always the case
    if (config.file_namespace.severity() == .off and
        config.file_struct.severity() == .off)
        return null;

    const session_arena = session.runtime.sessionArena();
    const tree = doc.tree(session);
    if (tree.errors.len > 0) return null;
    const abs_path = doc.absPath(session);
    const basename = std.fs.path.basename(abs_path);
    const stem = std.fs.path.stem(basename);
    const check_name = stem;

    const message, const severity = msg: {
        if (ast.isRootImplicitStruct(tree)) {
            if (config.file_struct.style()) |style| {
                if (!style.check(check_name)) {
                    break :msg .{
                        try std.fmt.allocPrint(
                            session_arena,
                            "File `{s}` is an implicit struct, so its name should be {s}",
                            .{ basename, style.name() },
                        ),
                        config.file_struct.severity(),
                    };
                }
            }
        } else if (config.file_namespace.style()) |style| {
            if (!style.check(check_name)) {
                break :msg .{
                    try std.fmt.allocPrint(
                        session_arena,
                        "File `{s}` is a namespace, so its name should be {s}",
                        .{ basename, style.name() },
                    ),
                    config.file_namespace.severity(),
                };
            }
        }

        return null;
    };

    var lint_problems = try session_arena.alloc(zlinter.results.LintProblem, 1);
    lint_problems[0] = .{
        .severity = severity,
        .rule_id = rule.rule_id,
        .start = .zero,
        .end = .zero,
        .message = message,
    };
    return try zlinter.results.LintResult.init(
        session_arena,
        abs_path,
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
                .file_struct = switch (severity) {
                    .off => .off,
                    .warning => .{ .warning = .title_case },
                    .@"error" => .{ .@"error" = .title_case },
                },
            },
            &.{.{
                .rule_id = "file_naming",
                .severity = severity,
                .slice = "",
                .message = "File `snake_case.zig` is an implicit struct, so its name should be TitleCase",
            }},
        );

        // namespace file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ pub const a = 1;
        ,
            .{ .filename = zlinter.testing.paths.posix("TitleCase.zig") },
            Config{
                .file_namespace = switch (severity) {
                    .off => .off,
                    .warning => .{ .warning = .snake_case },
                    .@"error" => .{ .@"error" = .snake_case },
                },
            },
            &.{.{
                .rule_id = "file_naming",
                .severity = severity,
                .slice = "",
                .message = "File `TitleCase.zig` is a namespace, so its name should be snake_case",
            }},
        );
    }
    // Off:
    {
        // Implicit struct file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ field_a: u32
        ,
            .{ .filename = zlinter.testing.paths.posix("snake_case.zig") },
            Config{
                .file_struct = .off,
            },
            &.{},
        );

        // namespace file:
        try zlinter.testing.testRunRule(
            buildRule(.{}),
            \\ pub const a = 1;
        ,
            .{ .filename = zlinter.testing.paths.posix("TitleCase.zig") },
            Config{
                .file_namespace = .off,
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

test "skips malformed source" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "pub const hit_points = ;",
        .{
            .filename = zlinter.testing.paths.posix("path/to/BadName.zig"),
            .allow_parse_errors = true,
        },
        Config{},
        &.{},
    );

    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "hit_points: ,",
        .{
            .filename = zlinter.testing.paths.posix("path/to/bad_name.zig"),
            .allow_parse_errors = true,
        },
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
                .message = "File `File.zig` is a namespace, so its name should be snake_case",
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
                .message = "File `myFile.zig` is a namespace, so its name should be snake_case",
            },
        },
    );
}

test "expects TitleCase with camelCase" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        "hit_points: f32,",
        .{
            .filename = zlinter.testing.paths.posix("path/to/myFile.zig"),
        },
        Config{ .file_struct = .{ .warning = .title_case } },
        &.{
            .{
                .rule_id = "file_naming",
                .severity = .warning,
                .slice = "",
                .message = "File `myFile.zig` is an implicit struct, so its name should be TitleCase",
            },
        },
    );
}

test "expects TitleCase with snake_case" {
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
                .message = "File `my_file.zig` is an implicit struct, so its name should be TitleCase",
            },
        },
    );
}

const std = @import("std");
const zlinter = @import("zlinter");
const ast = zlinter.ast;
