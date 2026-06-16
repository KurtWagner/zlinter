const TypeStore = @This();

summaries: std.ArrayList(TypeSummary),

pub const empty: TypeStore = .{
    .summaries = .empty,
};

pub const TypeId = enum(u32) {
    _,

    pub fn fromIndex(index: usize) TypeId {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: TypeId) usize {
        return @intFromEnum(self);
    }
};

// TODO: #149 - using this for compat with previous versions but can rethink this.
pub const Type = enum {
    /// Fallback when it's not a type or any of the identifiable `*_instance`
    /// kinds - usually this means its a primitive. e.g., `var age: u32 = 24;`
    other,
    /// e.g., has type `fn () void`
    @"fn",
    /// e.g., has type `fn () type`
    fn_returns_type,
    opaque_instance,
    /// e.g., has type `enum { ... }`
    enum_instance,
    /// e.g., has type `struct { field: u32 }`
    struct_instance,
    /// e.g., has type `union { a: u32, b: u32 }`
    union_instance,
    /// e.g., `const MyError = error { NotFound, Invalid };`
    error_type,
    /// e.g., `const Callback = *const fn () void;`
    fn_type,
    /// e.g., `const Callback = *const fn () void;`
    fn_type_returns_type,
    /// Is type `type` and not categorized as any other `*_type`
    type,
    /// e.g., `const Result = enum { good, bad };`
    enum_type,
    /// e.g., `const Person = struct { name: [] const u8 };`
    struct_type,
    /// e.g., `const colors = struct { const color = "red"; };`
    namespace_type,
    /// e.g., `const Color = union { rgba: Rgba, rgb: Rgb };`
    union_type,
    opaque_type,

    pub fn name(self: Type) []const u8 {
        return switch (self) {
            .other => "Other",
            .@"fn" => "Function",
            .fn_returns_type => "Type function",
            .opaque_instance => "Opaque instance",
            .enum_instance => "Enum instance",
            .struct_instance => "Struct instance",
            .union_instance => "Union instance",
            .error_type => "Error",
            .fn_type => "Function type",
            .fn_type_returns_type => "Type function type",
            .type => "Type",
            .enum_type => "Enum",
            .struct_type => "Struct",
            .namespace_type => "Namespace",
            .union_type => "Union",
            .opaque_type => "Opaque",
        };
    }
};

pub const TypeSummary = union(enum) {
    kind: Type,
    primitive: Primitive,
    reference: []const u8,

    pub fn coarseType(self: TypeSummary) Type {
        return switch (self) {
            .kind => |kind| kind,
            .primitive => .other,
            .reference => .other,
        };
    }

    fn eql(a: TypeSummary, b: TypeSummary) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .kind => |a_kind| a_kind == b.kind,
            .primitive => |a_primitive| a_primitive.eql(b.primitive),
            .reference => |a_reference| std.mem.eql(u8, a_reference, b.reference),
        };
    }
};

pub const Primitive = union(enum) {
    bool,
    number: Number,
    named: []const u8,

    pub const Number = struct {
        name: []const u8,
        kind: NumberKind,
        bits: ?u16 = null,

        fn eql(a: Primitive.Number, b: Primitive.Number) bool {
            return std.mem.eql(u8, a.name, b.name) and
                a.kind == b.kind and
                a.bits == b.bits;
        }
    };

    pub const NumberKind = enum {
        signed_int,
        unsigned_int,
        float,
        comptime_int,
        comptime_float,
    };

    fn eql(a: Primitive, b: Primitive) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .bool => true,
            .number => |a_number| a_number.eql(b.number),
            .named => |a_name| std.mem.eql(u8, a_name, b.named),
        };
    }
};

pub fn deinit(self: *TypeStore, gpa: std.mem.Allocator) void {
    self.summaries.deinit(gpa);
}

pub fn store(
    self: *TypeStore,
    gpa: std.mem.Allocator,
    type_summary: TypeSummary,
) TypeId {
    // TODO: #149 - optimise this
    for (self.summaries.items, 0..) |existing, index|
        if (existing.eql(type_summary)) return .fromIndex(index);

    const type_id: TypeId = .fromIndex(self.summaries.items.len);
    self.summaries.append(gpa, type_summary) catch @panic("OOM");
    return type_id;
}

pub fn summary(self: *const TypeStore, type_id: TypeId) TypeSummary {
    return self.summaries.items[type_id.toIndex()];
}

pub fn debugPrintSummary(summary_value: TypeSummary) void {
    switch (summary_value) {
        .kind => |kind| std.debug.print("{s}", .{kind.name()}),
        .primitive => |primitive| switch (primitive) {
            .bool => std.debug.print("bool", .{}),
            .number => |number| std.debug.print("{s}", .{number.name}),
            .named => |name| std.debug.print("{s}", .{name}),
        },
        .reference => |source| std.debug.print("{s}", .{source}),
    }
}
// TODO: #149 - perhaps this can be more general - `summarize(node)` and switches out instead of expecting caller to do it?
pub fn summarizeRoot() TypeSummary {
    return .{ .kind = .namespace_type };
}

pub fn summarizeFnProto(
    tree: *const Ast,
    fn_proto: Ast.full.FnProto,
    comptime as_type_value: bool,
) TypeSummary {
    const returns_type = if (fn_proto.ast.return_type.unwrap()) |return_node| returns_type: {
        const unwrapped_return = ast.unwrapNode(tree, return_node, .{});
        break :returns_type ast.isIdentiferKind(tree, unwrapped_return, .type);
    } else false;

    return .{
        .kind = if (as_type_value)
            if (returns_type) .fn_type_returns_type else .fn_type
        else if (returns_type) .fn_returns_type else .@"fn",
    };
}

pub fn summarizeVarDecl(
    tree: *const Ast,
    var_decl: Ast.full.VarDecl,
) ?TypeSummary {
    return summarizeDeclType(
        tree,
        var_decl.ast.type_node.unwrap(),
        var_decl.ast.init_node.unwrap(),
    );
}

pub fn summarizeContainerField(
    tree: *const Ast,
    field: Ast.full.ContainerField,
) ?TypeSummary {
    return summarizeDeclType(
        tree,
        field.ast.type_expr.unwrap(),
        field.ast.value_expr.unwrap(),
    );
}

pub fn summarizeValueNode(
    tree: *const Ast,
    value_node: Ast.Node.Index,
) ?TypeSummary {
    return summarizeValueExpr(tree, value_node);
}

pub fn summarizeFnReturnType(
    tree: *const Ast,
    fn_proto: Ast.full.FnProto,
) ?TypeSummary {
    const return_type = fn_proto.ast.return_type.unwrap() orelse return null;
    return summarizeTypeNode(tree, return_type);
}

pub fn summarizeTypeNode(
    tree: *const Ast,
    type_node: Ast.Node.Index,
) TypeSummary {
    return summarizeTypeExpr(tree, type_node) orelse
        .{ .reference = tree.getNodeSource(type_node) };
}

fn summarizeDeclType(
    tree: *const Ast,
    maybe_type_node: ?Ast.Node.Index,
    maybe_value_node: ?Ast.Node.Index,
) ?TypeSummary {
    if (maybe_type_node) |type_node| {
        return summarizeTypeNode(tree, type_node);
    }

    if (maybe_value_node) |value_node| {
        if (summarizeValueExpr(tree, value_node)) |summary_value| return summary_value;
    }

    return null;
}

fn summarizeTypeExpr(
    tree: *const Ast,
    type_node: Ast.Node.Index,
) ?TypeSummary {
    const node = ast.unwrapNode(tree, type_node, .{});

    if (tree.nodeTag(node) == .identifier) {
        const name = tree.getNodeSource(node);
        if (primitiveFromName(name)) |primitive| return .{ .primitive = primitive };
        if (std.mem.eql(u8, name, "type")) return .{ .kind = .type };
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return summarizeFnProto(tree, fn_proto, false);
    }

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
        return summarizeContainerDecl(tree, container_decl, .instance);
    }

    switch (tree.nodeTag(node)) {
        .error_set_decl,
        .merge_error_sets,
        => return .{ .kind = .error_type },
        else => return null,
    }
}

fn summarizeValueExpr(
    tree: *const Ast,
    value_node: Ast.Node.Index,
) ?TypeSummary {
    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_optional_unwrap = false,
    });

    switch (tree.nodeTag(node)) {
        .identifier => {
            const value = tree.getNodeSource(node);
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                return .{ .primitive = .bool };
            }
            if (std.mem.eql(u8, value, "type")) return .{ .kind = .type };
        },
        .number_literal => {
            const value = tree.getNodeSource(node);
            const kind: Primitive.NumberKind =
                if (std.mem.indexOfAny(u8, value, ".eE") == null)
                    .comptime_int
                else
                    .comptime_float;
            return .{ .primitive = .{ .number = .{
                .name = if (kind == .comptime_int) "comptime_int" else "comptime_float",
                .kind = kind,
            } } };
        },
        .error_set_decl,
        .merge_error_sets,
        => return .{ .kind = .error_type },
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            const builtin_name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, builtin_name, "@import")) return .{ .kind = .namespace_type };
            if (std.mem.eql(u8, builtin_name, "@Type") or std.mem.eql(u8, builtin_name, "@TypeOf")) {
                return .{ .kind = .type };
            }
        },
        else => {},
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return summarizeFnProto(tree, fn_proto, true);
    }

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
        return summarizeContainerDecl(tree, container_decl, .type_value);
    }

    return .{ .reference = tree.getNodeSource(value_node) };
}

fn summarizeContainerDecl(
    tree: *const Ast,
    container_decl: Ast.full.ContainerDecl,
    comptime mode: enum { instance, type_value },
) TypeSummary {
    const token_tag = tree.tokenTag(container_decl.ast.main_token);
    return .{ .kind = switch (token_tag) {
        .keyword_struct => switch (mode) {
            .instance => if (ast.isContainerNamespace(tree, container_decl)) .namespace_type else .struct_instance,
            .type_value => if (ast.isContainerNamespace(tree, container_decl)) .namespace_type else .struct_type,
        },
        .keyword_union => switch (mode) {
            .instance => .union_instance,
            .type_value => .union_type,
        },
        .keyword_opaque => switch (mode) {
            .instance => .opaque_instance,
            .type_value => .opaque_type,
        },
        .keyword_enum => switch (mode) {
            .instance => .enum_instance,
            .type_value => .enum_type,
        },
        inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
    } };
}

fn primitiveFromName(name: []const u8) ?Primitive {
    if (std.mem.eql(u8, name, "bool")) return .bool;

    if (std.mem.eql(u8, name, "comptime_int")) {
        return .{ .number = .{
            .name = name,
            .kind = .comptime_int,
        } };
    }

    if (std.mem.eql(u8, name, "comptime_float")) {
        return .{ .number = .{
            .name = name,
            .kind = .comptime_float,
        } };
    }

    if (std.mem.eql(u8, name, "usize")) {
        return .{ .number = .{
            .name = name,
            .kind = .unsigned_int,
        } };
    }

    if (std.mem.eql(u8, name, "isize")) {
        return .{ .number = .{
            .name = name,
            .kind = .signed_int,
        } };
    }

    if (name.len > 1 and (name[0] == 'u' or name[0] == 'i')) {
        if (parsePrimitiveIntBits(name[1..])) |bits| {
            return .{ .number = .{
                .name = name,
                .kind = if (name[0] == 'u') .unsigned_int else .signed_int,
                .bits = bits,
            } };
        }
    }

    if (name.len > 1 and name[0] == 'f') {
        if (parsePrimitiveIntBits(name[1..])) |bits| {
            return .{ .number = .{
                .name = name,
                .kind = .float,
                .bits = bits,
            } };
        }
    }

    inline for (&.{ "void", "noreturn" }) |primitive_name| {
        if (std.mem.eql(u8, name, primitive_name)) return .{ .named = name };
    }

    return null;
}

fn parsePrimitiveIntBits(text: []const u8) ?u16 {
    if (text.len == 0) return null;

    var value: u16 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = std.math.mul(u16, value, 10) catch return null;
        value = std.math.add(u16, value, c - '0') catch return null;
    }

    return value;
}

const Ast = std.zig.Ast;
const ast = @import("../ast.zig");
const std = @import("std");
