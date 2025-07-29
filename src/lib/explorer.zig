//! Module providing methods for exploring the Zig AST, usually outside the
//! scope a linter rule. e.g., for educational purposes.

pub fn parseToJsonStringAlloc(source: [:0]const u8, gpa: std.mem.Allocator) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    return std.json.Stringify.valueAlloc(gpa, try parseToJsonTree(source, arena.allocator()), .{});
}

pub fn parseToJsonTree(source: [:0]const u8, arena: std.mem.Allocator) !std.json.Value {
    const tree = try std.zig.Ast.parse(arena, source, .zig);
    return jsonTree(tree, arena);
}

pub fn jsonTree(
    tree: std.zig.Ast,
    arena: std.mem.Allocator,
) !std.json.Value {
    var root_json_object = std.json.ObjectMap.init(arena);
    try root_json_object.put(
        "tokens",
        .{ .array = try tokensToJson(tree, arena) },
    );

    try root_json_object.put(
        "errors",
        .{ .array = try errorsToJson(tree, arena) },
    );

    if (tree.errors.len == 0) {
        if (switch (version.zig) {
            .@"0.14" => tree.render(arena),
            .@"0.15" => tree.renderAlloc(arena),
        }) |rendering| {
            try root_json_object.put(
                "render",
                .{ .string = rendering },
            );
        } else |_| {}
    }

    const Context = struct {
        arena: std.mem.Allocator,
        indent: u32 = 0,
        node_children: *std.json.Array,

        fn callback(self: @This(), context_tree: std.zig.Ast, child_node: std.zig.Ast.Node.Index) error{OutOfMemory}!void {
            if (shims.NodeIndexShim.init(child_node).isRoot()) return;

            var node_object = std.json.ObjectMap.init(self.arena);
            try node_object.put("tag", .{
                .string = @tagName(shims.nodeTag(context_tree, child_node)),
            });

            try node_object.put("main_token", .{
                .integer = shims.nodeMainToken(context_tree, child_node),
            });
            try node_object.put("first_token", .{
                .integer = context_tree.firstToken(child_node),
            });
            try node_object.put("last_token", .{
                .integer = context_tree.lastToken(child_node),
            });
            // Add more meta data for nodes here...
            // e.g., the "data" union structures

            var node_children = std.json.Array.init(self.arena);
            try ast.iterateChildren(
                context_tree,
                child_node,
                @This(){
                    .node_children = &node_children,
                    .arena = self.arena,
                    .indent = self.indent + 2,
                },
                error{OutOfMemory},
                callback,
            );

            try node_object.put("body", .{ .array = node_children });

            try self.node_children.append(.{
                .object = node_object,
            });
        }
    };

    var root_node_json_object = std.json.ObjectMap.init(arena);

    try root_node_json_object.put(
        "tag",
        .{ .string = "root" },
    );

    var root_node_children = std.json.Array.init(arena);

    if (tree.errors.len == 0) {
        try ast.iterateChildren(
            tree,
            shims.NodeIndexShim.root.toNodeIndex(),
            Context{
                .arena = arena,
                .indent = 0,
                .node_children = &root_node_children,
            },
            error{OutOfMemory},
            Context.callback,
        );
    }

    try root_json_object.put("body", .{ .array = root_node_children });

    return std.json.Value{ .object = root_json_object };
}

fn errorsToJson(tree: std.zig.Ast, arena: std.mem.Allocator) !std.json.Array {
    var json_errors = std.json.Array.init(arena);

    for (tree.errors) |e| {
        var json_error = std.json.ObjectMap.init(arena);

        try json_error.put("tag", .{ .string = @tagName(e.tag) });
        try json_error.put("is_note", .{ .bool = e.is_note });
        try json_error.put("token_is_prev", .{ .bool = e.token_is_prev });
        try json_error.put("token", .{ .integer = e.token });

        switch (version.zig) {
            .@"0.14" => {
                var render_backing = std.ArrayListUnmanaged(u8).empty;
                try tree.renderError(e, render_backing.writer(arena));
                try json_error.put("message", .{ .string = try render_backing.toOwnedSlice(arena) });
            },
            .@"0.15" => {
                var aw = std.Io.Writer.Allocating.init(arena);
                try tree.renderError(e, &aw.writer);
                try json_error.put("message", .{ .string = try aw.toOwnedSlice() });
            },
        }

        try json_errors.append(.{ .object = json_error });
    }

    return json_errors;
}

fn tokensToJson(tree: std.zig.Ast, arena: std.mem.Allocator) !std.json.Array {
    var json_tokens = std.json.Array.init(arena);

    var token_index: std.zig.Ast.TokenIndex = 0;
    while (token_index < tree.tokens.len) : (token_index += 1) {
        const loc = tree.tokenLocation(
            0,
            token_index,
        );
        const start_offset = loc.line_start + loc.column;

        var token_object = std.json.ObjectMap.init(arena);
        try token_object.put("tag", std.json.Value{
            .string = @tagName(tree.tokens.items(.tag)[token_index]),
        });
        try token_object.put("start", std.json.Value{
            .number_string = try std.fmt.allocPrint(arena, "{d}", .{start_offset}),
        });
        try token_object.put("len", std.json.Value{
            .number_string = try std.fmt.allocPrint(arena, "{d}", .{tree.tokenSlice(token_index).len}),
        });
        // Add more meta data for tokens here..

        try json_tokens.append(.{ .object = token_object });
    }

    return json_tokens;
}

const std = @import("std");
const shims = @import("shims.zig");
const version = @import("version.zig");
const ast = @import("ast.zig");
