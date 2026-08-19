//! Enforces rules on the projects `build.zig.zon` configuration file.

/// Config for build_zig_zon rule.
pub const Config = struct {
    /// Whether or not a LICENSE file is required in the `paths` field. It's
    /// important because many licenses require the license to accompany
    /// redistributed copies of the source code.
    ///
    /// License files are case insensitive "LICENSE", "LICENSE.md" or "LICENSE.txt".
    require_license_path: zlinter.rules.LintProblemSeverity = .@"error",
};

/// Builds and returns the build_zig_zon rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;

    return zlinter.rules.LintRule{
        .rule_id = @tagName(.build_zig_zon),
        .run = &run,
        .target = .zon,
    };
}

/// Runs the build_zig_zon rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const zone = zlinter.tracy.traceNamed(@src(), "rule.build_zig_zon");
    defer zone.end();
    zone.addText(doc.absPath(session));

    if (!std.mem.eql(u8, std.Io.Dir.path.basename(doc.absPath(session)), "build.zig.zon"))
        return null;

    const session_arena = session.runtime.sessionArena();
    var lint_problems: std.ArrayList(zlinter.results.LintProblem) = .empty;

    const config = options.getConfig(Config);
    if (checkRequireLicensePath(rule, session, doc, config)) |problem|
        lint_problems.append(session_arena, problem) catch @panic("OOM");

    return if (lint_problems.items.len > 0)
        zlinter.results.LintResult.init(
            doc.file_id,
            lint_problems.items,
        ) catch @panic("OOM")
    else
        null;
}

fn checkRequireLicensePath(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    config: Config,
) ?zlinter.results.LintProblem {
    if (config.require_license_path == .off) return null;

    const tree = doc.tree(session);
    const root_init_node = tree.nodeData(.root).node;

    var struct_init_buffer: [2]Ast.Node.Index = undefined;
    const root_init = tree.fullStructInit(
        &struct_init_buffer,
        root_init_node,
    ) orelse return null;

    var seen_paths = false;
    fields: for (root_init.ast.fields) |init_node| {
        const name_token = fieldIdentifierToken(tree, init_node) orelse
            continue :fields;

        if (!std.mem.eql(u8, tree.tokenSlice(name_token), "paths"))
            continue :fields;
        seen_paths = true;

        if (!arrayInitContainsLicensePath(tree, init_node)) {
            const session_arena = session.runtime.sessionArena();
            return .{
                .start = .startOfToken(tree, name_token),
                .end = .endOfToken(tree, name_token),
                .message = session_arena.dupe(u8, "build.zig.zon paths must include LICENSE") catch @panic("OOM"),
                .rule_id = rule.rule_id,
                .severity = config.require_license_path,
            };
        }
    }

    if (!seen_paths) {
        const session_arena = session.runtime.sessionArena();
        return .{
            .start = .startOfNode(tree, root_init_node),
            .end = .endOfNode(tree, root_init_node),
            .message = session_arena.dupe(u8, "build.zig.zon paths must include LICENSE but no paths were set") catch @panic("OOM"),
            .rule_id = rule.rule_id,
            .severity = config.require_license_path,
        };
    }

    return null;
}

/// Returns a fields identifier token from its init node
fn fieldIdentifierToken(
    tree: Ast,
    init_node: Ast.Node.Index,
) ?Ast.TokenIndex {
    const first_token = tree.firstToken(init_node);

    // e.g., `.<name token> = <first token>`
    return if (!tree.isTokenPrecededByTags(first_token, &.{ .equal, .identifier, .period }))
        first_token - 2
    else
        null;
}

/// Returns true if the node is an array init containing a license path.
fn arrayInitContainsLicensePath(tree: Ast, node: Ast.Node.Index) bool {
    var array_init_buffer: [2]Ast.Node.Index = undefined;
    const array_init = tree.fullArrayInit(&array_init_buffer, node) orelse
        return false;

    for (array_init.ast.elements) |element|
        if (isLicensePath(tree, element))
            return true;

    return false;
}

/// Returns true of the node is a string literal that's a valid license file path
fn isLicensePath(tree: Ast, string_node: Ast.Node.Index) bool {
    if (tree.nodeTag(string_node) != .string_literal) return false;

    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const raw = tree.tokenSlice(tree.nodeMainToken(string_node));

    const path = switch (std.zig.string_literal.parseWrite(&writer, raw) catch return false) {
        .success => path: {
            writer.flush() catch return false;
            break :path writer.buffer[0..writer.end];
        },
        .failure => return false,
    };

    const basename = std.Io.Dir.path.basename(path);
    return std.ascii.eqlIgnoreCase(basename, "LICENSE") or
        std.ascii.eqlIgnoreCase(basename, "LICENSE.md") or
        std.ascii.eqlIgnoreCase(basename, "LICENSE.txt");
}

test "require_license_path reports without paths" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .missing_license_path,
        \\    .version = "0.0.0",
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/build.zig.zon") },
        Config{ .require_license_path = .@"error" },
        &.{
            .{
                .rule_id = "build_zig_zon",
                .severity = .@"error",
                .slice =
                \\.{
                \\    .name = .missing_license_path,
                \\    .version = "0.0.0",
                \\}
                ,
                .message = "build.zig.zon paths must include LICENSE but no paths were set",
            },
        },
    );
}

test "require_license_path reports paths without LICENSE" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .missing_license_path,
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/build.zig.zon") },
        Config{ .require_license_path = .warning },
        &.{
            .{
                .rule_id = "build_zig_zon",
                .severity = .warning,
                .slice = "paths",
                .message = "build.zig.zon paths must include LICENSE",
            },
        },
    );
}

test "require_license_path allows paths with LICENSE" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .valid_license_path,
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "LICENSE",
        \\        "src",
        \\    },
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/build.zig.zon") },
        Config{ .require_license_path = .@"error" },
        &.{},
    );
}

test "require_license_path allows paths with relative LICENSE" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .valid_license_path,
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "./LICENSE",
        \\        "src",
        \\    },
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/build.zig.zon") },
        Config{ .require_license_path = .@"error" },
        &.{},
    );
}

test "require_license_path allows paths with case-insensitive LICENSE extension" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .valid_license_path,
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "docs/license.MD",
        \\        "src",
        \\    },
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/build.zig.zon") },
        Config{ .require_license_path = .@"error" },
        &.{},
    );
}

test "require_license_path respects require_license_path off" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .require_license_path_off,
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/build.zig.zon") },
        Config{ .require_license_path = .off },
        &.{},
    );
}

test "require_license_path ignores other zon files" {
    try zlinter.testing.testRunRule(
        buildRule(.{}),
        \\.{
        \\    .name = .not_build_zig_zon,
        \\    .version = "0.0.0",
        \\    .paths = .{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    },
        \\}
        \\
    ,
        .{ .filename = zlinter.testing.paths.posix("path/to/package.zig.zon") },
        Config{ .require_license_path = .@"error" },
        &.{},
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");

const Ast = std.zig.Ast;
