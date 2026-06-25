//! Enforce a consistent, predictable order for fields in structs, enums, and unions.
//!
//! `field_ordering` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places.
//!
//! **Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**

/// Config for field_ordering rule.
pub const Config = struct {
    /// Order and severity for union fields. If you're setting this and use
    /// tagged unions (e.g., `union(MyEnum)`) then you will also need to set
    /// the same order for enums.
    union_field_order: zlinter.rules.LintTextOrderWithSeverity = .{
        .order = .alphabetical_ascending,
        .severity = .warning,
    },

    /// Order and severity for struct fields
    struct_field_order: zlinter.rules.LintTextOrderWithSeverity = .off,

    /// Whether to check order of packed structs (e.g., `packed struct(u32) { .. }`).
    /// You probably never want to enforce order of packed structs, so best to
    /// leave as `true` unless you're certain.
    exclude_packed_structs: bool = true,

    /// Whether to check order of extern structs (e.g., `extern struct { .. }`).
    /// You probably never want to enforce order of extern structs, so best to
    /// leave as `true` unless you're certain.
    exclude_extern_structs: bool = true,

    /// Order and severity for enum fields. If you're setting this and use
    /// tagged unions (e.g., `union(MyEnum)`) then you will also need to set
    /// the same order for unions.
    enum_field_order: zlinter.rules.LintTextOrderWithSeverity = .{
        .order = .alphabetical_ascending,
        .severity = .warning,
    },
};

/// Builds and returns the field_ordering rule.
pub fn buildRule(options: zlinter.rules.RuleOptions) zlinter.rules.LintRule {
    _ = options;
    return zlinter.rules.LintRule{
        .rule_id = @tagName(.field_ordering),
        .run = &run,
    };
}

/// Runs the field_ordering rule.
fn run(
    rule: zlinter.rules.LintRule,
    session: *zlinter.session.LintSession,
    doc: *const zlinter.session.LintDocument,
    options: zlinter.rules.RunOptions,
) zlinter.rules.RunError!?zlinter.results.LintResult {
    const config = options.getConfig(Config);
    const session_arena = session.runtime.sessionArena();
    const rule_arena = session.runtime.ruleArena();

    var lint_problems = std.ArrayList(zlinter.results.LintProblem).empty;
    const tree = doc.tree(session);

    const root: Ast.Node.Index = .root;
    var it = try doc.nodeLineageIterator(root, rule_arena);

    var container_decl_buffer: [2]Ast.Node.Index = undefined;

    nodes: while (try it.next()) |tuple| {
        const node, const connections = tuple;

        const order_with_severity: zlinter.rules.LintTextOrderWithSeverity, const container_kind_name: []const u8 = kind: {
            if (tree.fullContainerDecl(
                &container_decl_buffer,
                node,
            )) |container_decl| {
                break :kind switch (tree.tokens.items(.tag)[tree.nodeMainToken(node)]) {
                    .keyword_union => .{ config.union_field_order, "Union" },
                    .keyword_struct => {
                        if (container_decl.layout_token) |layout_token| {
                            if (config.exclude_extern_structs and tree.tokens.items(.tag)[layout_token] == .keyword_extern) {
                                break :kind null;
                            }
                            if (config.exclude_packed_structs and tree.tokens.items(.tag)[layout_token] == .keyword_packed) {
                                break :kind null;
                            }
                        }
                        break :kind .{ config.struct_field_order, "Struct" };
                    },
                    .keyword_enum => .{ config.enum_field_order, "Enum" },
                    else => null,
                };
            }
            break :kind null;
        } orelse continue :nodes;

        if (order_with_severity.order == .off or order_with_severity.severity == .off) {
            continue :nodes;
        }

        var actual_order = std.ArrayList(Ast.Node.Index).empty;
        var expected_order = std.ArrayList(Ast.Node.Index).empty;

        var sorted_queue: std.PriorityQueue(
            Field,
            struct { zlinter.rules.LintTextOrder },
            Field.cmp,
        ) = .initContext(.{order_with_severity.order});

        var seen_field: bool = false;
        var original_index: usize = 0;
        children: for (connections.children orelse &.{}) |container_child| {
            // Declarations cannot appear between fields so once we see a field
            // simply read until we see something else to identify the chunk of
            // fields in source:
            const name_token = token: switch (tree.nodeTag(container_child)) {
                .container_field_init,
                .container_field_align,
                .container_field,
                => {
                    seen_field = true;
                    break :token tree.nodeMainToken(container_child);
                },
                else => if (seen_field) break :children else continue :children,
            };

            try actual_order.append(rule_arena, container_child);
            try sorted_queue.push(rule_arena, .{
                .name = tree.tokenSlice(name_token),
                .node = container_child,
                .original_index = original_index,
            });
            original_index += 1;
        }

        // Find the first and last field that are out of order (if any)
        var i: usize = 0;
        var maybe_first_problem_index: ?usize = null; // Inclusive
        var maybe_last_problem_index: ?usize = null; // Inclusive
        while (sorted_queue.pop()) |field| : (i += 1) {
            try expected_order.append(rule_arena, field.node);
            if (field.node != actual_order.items[i]) {
                maybe_first_problem_index = maybe_first_problem_index orelse i;
                maybe_last_problem_index = i;
            }
        }

        if (maybe_first_problem_index) |first_problem_index| {
            const last_problem_index = maybe_last_problem_index.?;
            const container_end_token = tree.lastToken(node);

            const actual_start, const actual_end =
                nodeSpanIncludingComments(
                    tree,
                    actual_order.items[first_problem_index],
                    actual_order.items[last_problem_index],
                    .{
                        .consume_trailing_comma = true,
                    },
                );
            const first_fix_segment = fieldSegmentForFix(
                tree,
                actual_order.items[first_problem_index],
                container_end_token,
            );
            const last_fix_segment = fieldSegmentForFix(
                tree,
                actual_order.items[last_problem_index],
                container_end_token,
            );

            var expected_writer: std.Io.Writer.Allocating = .init(session_arena);

            const last_node = expected_order.items[expected_order.items.len - 1];
            for (expected_order.items[first_problem_index .. last_problem_index + 1]) |current_node| {
                const is_last_field = current_node == last_node;
                const segment = fieldSegmentForFix(
                    tree,
                    current_node,
                    container_end_token,
                );
                const needs_comma = !segment.had_trailing_comma and (!is_last_field or segment.is_multiline);
                const remove_comma = segment.had_trailing_comma and is_last_field and !segment.is_multiline;

                writeFieldSegmentForFix(
                    &expected_writer.writer,
                    tree.source,
                    segment,
                    needs_comma,
                    remove_comma,
                ) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                };
            }

            try lint_problems.append(session_arena, .{
                .rule_id = rule.rule_id,
                .severity = order_with_severity.severity,
                .start = actual_start,
                .end = actual_end,
                .message = try std.fmt.allocPrint(session_arena, "{s} fields should be in {s} order", .{
                    container_kind_name,
                    order_with_severity.order.name(),
                }),
                .fix = .{
                    .start = first_fix_segment.start,
                    .end = last_fix_segment.end_exclusive,
                    .text = try expected_writer.toOwnedSlice(),
                },
            });
        }
    }

    return if (lint_problems.items.len > 0)
        try zlinter.results.LintResult.init(
            session_arena,
            doc.absPath(session),
            lint_problems.items,
        )
    else
        null;
}

/// Span between two nodes (or the same node) including comments and leading
/// whitespace like newlines.
fn nodeSpanIncludingComments(
    tree: Ast,
    first_node: Ast.Node.Index,
    last_node: Ast.Node.Index,
    options: struct { consume_trailing_comma: bool = false },
) struct {
    zlinter.results.LintProblemLocation,
    zlinter.results.LintProblemLocation,
} {
    const first_token = firstTokenIncludingComments(tree, first_node);
    const prev_end: zlinter.results.LintProblemLocation = .endOfToken(tree, first_token - 1);
    const start: zlinter.results.LintProblemLocation = .{
        .byte_offset = prev_end.byte_offset + 1,
    };

    var last_token = tree.lastToken(last_node);
    if (options.consume_trailing_comma and tree.tokens.items(.tag)[last_token + 1] == .comma) last_token += 1;
    const end: zlinter.results.LintProblemLocation = .endOfToken(tree, last_token);

    return .{ start, end };
}

const FieldSegment = struct {
    start: usize,
    end_exclusive: usize,
    had_trailing_comma: bool,
    trailing_comma_start: ?usize,
    is_multiline: bool,
    trailing_comment_start: ?usize,
};

fn fieldSegmentForFix(
    tree: Ast,
    field_node: Ast.Node.Index,
    container_end_token: Ast.TokenIndex,
) FieldSegment {
    const source = tree.source;
    const container_end = tree.tokenStart(container_end_token);

    const start = fieldSegmentStart(
        source,
        tree.tokenStart(tree.firstToken(field_node)),
    );
    const last_token = tree.lastToken(field_node);
    const token_end = tree.tokenStart(last_token) +
        tree.tokenSlice(last_token).len;

    var end = token_end;
    var had_trailing_comma = false;
    var trailing_comma_start: ?usize = null;
    var trailing_comment_start: ?usize = null;

    var cursor = token_end;
    while (cursor < container_end and
        isHorizontalWhitespace(source[cursor])) : (cursor += 1)
    {}

    if (cursor < container_end and source[cursor] == ',') {
        had_trailing_comma = true;
        trailing_comma_start = cursor;
        cursor += 1;
        end = cursor;

        while (cursor < container_end and isHorizontalWhitespace(source[cursor])) : (cursor += 1) {}
        if (startsLineComment(source, cursor)) {
            trailing_comment_start = cursor;
            end = lineEndIncludingNewline(source, cursor);
        } else {
            if (cursor < container_end and source[cursor] == '\r') {
                cursor += 1;
                if (cursor < container_end and source[cursor] == '\n') cursor += 1;
                end = cursor;
            } else if (cursor < container_end and source[cursor] == '\n')
                end = cursor + 1;
        }
    } else if (startsLineComment(source, cursor)) {
        trailing_comment_start = cursor;
        end = lineEndIncludingNewline(source, cursor);
    }

    return .{
        .start = start,
        .end_exclusive = end,
        .had_trailing_comma = had_trailing_comma,
        .trailing_comma_start = trailing_comma_start,
        .is_multiline = std.mem.indexOfScalar(
            u8,
            source[start..end],
            '\n',
        ) != null,
        .trailing_comment_start = trailing_comment_start,
    };
}

fn writeFieldSegmentForFix(
    writer: *std.Io.Writer,
    source: []const u8,
    segment: FieldSegment,
    insert_comma: bool,
    remove_comma: bool,
) std.Io.Writer.Error!void {
    const segment_source = source[segment.start..segment.end_exclusive];
    if (remove_comma) {
        const comma_start = segment.trailing_comma_start.?;
        try writer.writeAll(source[segment.start..comma_start]);
        return writer.writeAll(source[comma_start + 1 .. segment.end_exclusive]);
    }

    if (!insert_comma)
        return writer.writeAll(segment_source);

    const insert_at = if (segment.trailing_comment_start) |comment_start|
        trimHorizontalWhitespaceEnd(source, segment.start, comment_start)
    else
        trimLineEndingAndHorizontalWhitespaceEnd(
            source,
            segment.start,
            segment.end_exclusive,
        );

    try writer.writeAll(source[segment.start..insert_at]);
    try writer.writeByte(',');
    try writer.writeAll(source[insert_at..segment.end_exclusive]);
}

fn fieldSegmentStart(source: []const u8, field_token_start: usize) usize {
    const line_start = lineStart(source, field_token_start);
    var inline_start = field_token_start;

    while (inline_start > line_start and
        isHorizontalWhitespace(source[inline_start - 1])) : (inline_start -= 1)
    {}
    if (inline_start > line_start) return inline_start;

    var start = line_start;
    var cursor = line_start;

    while (cursor > 0) {
        const previous_line_end = cursor - 1;
        const previous_line_start = lineStart(source, previous_line_end);
        const previous_line = trimLine(source[previous_line_start..previous_line_end]);

        if (std.mem.startsWith(u8, previous_line, "//")) {
            start = previous_line_start;
            cursor = previous_line_start;
            continue;
        }

        if (previous_line.len == 0) {
            start = previous_line_start;
            cursor = previous_line_start;
            continue;
        }

        break;
    }

    return start;
}

fn lineStart(source: []const u8, offset: usize) usize {
    var cursor = offset;
    while (cursor > 0 and source[cursor - 1] != '\n') : (cursor -= 1) {}
    return cursor;
}

fn lineEndIncludingNewline(source: []const u8, offset: usize) usize {
    var cursor = offset;
    while (cursor < source.len and source[cursor] != '\n') : (cursor += 1) {}
    return if (cursor < source.len) cursor + 1 else cursor;
}

fn trimLine(line: []const u8) []const u8 {
    return std.mem.trim(u8, line, " \t\r");
}

fn trimHorizontalWhitespaceEnd(source: []const u8, start: usize, end: usize) usize {
    var cursor = end;
    while (cursor > start and
        isHorizontalWhitespace(source[cursor - 1])) : (cursor -= 1)
    {}
    return cursor;
}

fn trimLineEndingAndHorizontalWhitespaceEnd(source: []const u8, start: usize, end: usize) usize {
    var cursor = end;
    if (cursor > start and source[cursor - 1] == '\n') cursor -= 1;
    if (cursor > start and source[cursor - 1] == '\r') cursor -= 1;
    return trimHorizontalWhitespaceEnd(source, start, cursor);
}

fn isHorizontalWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

fn startsLineComment(source: []const u8, offset: usize) bool {
    return offset + 1 < source.len and source[offset] == '/' and source[offset + 1] == '/';
}

fn firstTokenIncludingComments(tree: Ast, node: Ast.Node.Index) Ast.TokenIndex {
    var token = tree.firstToken(node);
    while (tree.tokens.items(.tag)[token - 1] == .doc_comment) token -= 1;
    return token;
}

const Field = struct {
    name: []const u8,
    node: Ast.Node.Index,
    original_index: usize,

    fn cmp(session: struct { zlinter.rules.LintTextOrder }, lhs: Field, rhs: Field) std.math.Order {
        const order = session.@"0";
        return switch (order.cmp(lhs.name, rhs.name)) {
            .eq => std.math.order(lhs.original_index, rhs.original_index),
            else => |name_order| name_order,
        };
    }
};

test "Field.cmp preserves source order for equal names" {
    const first: Field = .{
        .name = "duplicate",
        .node = .root,
        .original_index = 0,
    };
    const second: Field = .{
        .name = "duplicate",
        .node = .root,
        .original_index = 1,
    };

    try std.testing.expectEqual(
        std.math.Order.lt,
        Field.cmp(.{.alphabetical_ascending}, first, second),
    );
    try std.testing.expectEqual(
        std.math.Order.gt,
        Field.cmp(.{.alphabetical_descending}, second, first),
    );
}

test {
    std.testing.refAllDecls(@This());
}

const std = @import("std");
const zlinter = @import("zlinter");
const Ast = std.zig.Ast;
