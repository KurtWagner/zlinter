/// The zig source file currently being linted, this typically only lives
/// for the duration of that single file being linted so it suited for
/// context only ever relevant to it.
const LintDocument = @This();

abs_path: []const u8,
handle: *zls.DocumentStore.Handle,
lineage: ast.NodeLineage,
comments: comments_module.CommentsDocument,
skipper: comments_module.LazyRuleSkipper,

pub fn deinit(self: *LintDocument, gpa: std.mem.Allocator) void {
    while (self.lineage.pop()) |connections| {
        connections.deinit(gpa);
    }

    self.lineage.deinit(gpa);
    gpa.free(self.abs_path);
    self.comments.deinit(gpa);
    self.skipper.deinit();
}

/// Returns true if the problem should be skipped based on line level
/// disable comments.
pub fn shouldSkipProblem(self: *LintDocument, problem: LintProblem) error{OutOfMemory}!bool {
    return self.skipper.shouldSkip(problem);
}

/// Walks up from a current node up its ansesters (e.g., parent,
/// grandparent, etc) until it reaches the root node of the document.
///
/// This will not include the given node, only its ancestors.
pub fn nodeAncestorIterator(
    self: *const LintDocument,
    node: Ast.Node.Index,
) ast.NodeAncestorIterator {
    return .{
        .current = node,
        .lineage = &self.lineage,
    };
}

/// Walks down from the current node does its children.
///
/// This includes the given node in the traversal.
pub fn nodeLineageIterator(
    self: *const LintDocument,
    node: Ast.Node.Index,
    gpa: std.mem.Allocator,
) error{OutOfMemory}!ast.NodeLineageIterator {
    var it = ast.NodeLineageIterator{
        .gpa = gpa,
        .queue = .empty,
        .lineage = &self.lineage,
    };
    try it.queue.append(gpa, node);
    return it;
}

/// Returns true if the given node appears within a `test {..}` declaration
/// block or a `if (builtin.is_test) {..}` block.
///
/// This is an imperfect heuristic but should be good enough for majority
/// of cases. A more complete solution would require building tests and
/// seeing whats included thats not in non-test builds, which is probably
/// out of scope for this linter.
pub fn isEnclosedInTestBlock(self: *const LintDocument, node: Ast.Node.Index) bool {
    var next = node;
    while (self.lineage.items(.parent)[@intFromEnum(next)]) |parent| {
        switch (self.handle.tree.nodeTag(parent)) {
            .test_decl => return true,
            .@"if", .if_simple => if (common.isTestOnlyCondition(
                self.handle.tree,
                self.handle.tree.fullIf(parent).?,
            )) {
                return true;
            },
            else => {},
        }
        next = parent;
    }
    return false;
}

test "LintDocument.isEnclosedInTestBlock" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var context: LintContext = undefined;
    try context.init(.{}, std.testing.io, std.testing.allocator, arena.allocator());
    defer context.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const source =
        \\pub fn main() void {
        \\ const is_not_in_test = 1;
        \\
        \\ if (builtin.is_test) {
        \\  const is_in_test_if_condition_a = 1;
        \\ }
        \\ if (anything.is_test) {
        \\  const is_in_test_if_condition_b = 1;
        \\ }
        \\ if (is_test) {
        \\  const is_in_test_if_condition_c = 1;
        \\ }
        \\ if (something) {
        \\    const is_not_in_test_nested_if_condition_a = 1;
        \\    if (is_test) {
        \\      const is_in_test_nested_if_condition_a = 1;
        \\    }
        \\ }
        \\ if (is_test) {
        \\    const is_in_test_nested_if_condition_c = 1;
        \\    if (something) {
        \\      const is_in_test_nested_if_condition_b = 1;
        \\    }
        \\ }
        \\ if (other) {
        \\  const is_not_in_test_if_condition = 1;
        \\ }
        \\}
        \\
        \\test {
        \\ const is_in_test_without_name = 1;
        \\}
        \\
        \\test "with name" {
        \\ const is_in_test_with_name = 1;
        \\}
    ;

    const doc = try testing.loadFakeDocument(
        &context,
        tmp.dir,
        "test.zig",
        source,
        arena.allocator(),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_without_name",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_a",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_b",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_if_condition_c",
        )),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test_if_condition",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_a",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_b",
        )),
    );

    try std.testing.expect(
        doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_in_test_nested_if_condition_c",
        )),
    );

    try std.testing.expect(
        !doc.isEnclosedInTestBlock(try testing.expectVarDecl(
            doc.handle.tree,
            "is_not_in_test_nested_if_condition_a",
        )),
    );
}

const ast = @import("../ast.zig");
const comments_module = @import("../comments.zig");
const common = @import("common.zig");
const std = @import("std");
const testing = @import("../testing.zig");
const zls = @import("zls");
const LintContext = @import("LintContext.zig");
const LintProblem = @import("../results.zig").LintProblem;
const Ast = std.zig.Ast;

test {
    std.testing.refAllDecls(@This());
}
