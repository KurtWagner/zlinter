const TypeStore = @This();

summaries: std.ArrayList(TypeSummary),
type_id_by_summary: std.HashMapUnmanaged(
    TypeSummary,
    TypeId,
    TypeSummaryContext,
    std.hash_map.default_max_load_percentage,
),

pub const empty: TypeStore = .{
    .summaries = .empty,
    .type_id_by_summary = .empty,
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

pub const Type = enum {
    /// Fallback when the summary cannot identify the expression as any known
    /// type category yet.
    unknown,
    /// Fallback when it's not a type or any of the identifiable `*_instance`
    /// kinds - usually this means its a primitive. e.g., `var age: u32 = 24;`
    other,
    primitive,
    /// e.g., has type `fn () void`
    @"fn",
    /// e.g., has type `fn () type`
    fn_returns_type,
    /// A value that is an instance of a container type.
    instance,
    /// A value whose Zig type is `type`.
    type,
    /// e.g., []const u8
    slice,
    /// e.g., [10]u8
    array,

    pub fn name(self: Type) []const u8 {
        return switch (self) {
            .unknown => "Unknown",
            .other => "Other",
            .primitive => "Primitive",
            .@"fn" => "Function",
            .fn_returns_type => "Type function",
            .instance => "Instance",
            .type => "Type",
            .slice => "Slice",
            .array => "Array",
        };
    }
};

pub const TypeSummary = union(Type) {
    unknown,
    other,
    primitive: Primitive,
    @"fn",
    fn_returns_type,
    instance: InstanceValue,
    type: TypeValue,
    slice: Slice,
    array: Array,

    pub fn coarseType(self: TypeSummary) Type {
        return std.meta.activeTag(self);
    }

    pub fn typeValueKind(self: TypeSummary) ?TypeValue.Kind {
        return switch (self) {
            .type => |type_value| type_value.kind,
            else => null,
        };
    }

    pub fn instanceValueKind(self: TypeSummary) ?InstanceValue.Kind {
        return switch (self) {
            .instance => |instance_value| instance_value.kind,
            else => null,
        };
    }

    pub fn isTypeValue(self: TypeSummary) bool {
        return std.meta.activeTag(self) == .type;
    }

    pub fn eql(a: TypeSummary, b: TypeSummary) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .primitive => |a_primitive| a_primitive.eql(b.primitive),
            .type => |a_type| a_type.eql(b.type),
            .instance => |a_instance| a_instance.eql(b.instance),
            .slice => |a_slice| a_slice.eql(b.slice),
            .array => |a_array| a_array.eql(b.array),
            else => true,
        };
    }

    pub fn hash(self: TypeSummary) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, std.meta.activeTag(self));

        switch (self) {
            .primitive => |primitive| std.hash.autoHash(&wy, primitive.hash()),
            .type => |type_value| std.hash.autoHash(&wy, type_value.hash()),
            .instance => |instance_value| std.hash.autoHash(&wy, instance_value.hash()),
            .slice => |slice_value| std.hash.autoHash(&wy, slice_value.hash()),
            .array => |array_value| std.hash.autoHash(&wy, array_value.hash()),
            else => {},
        }

        return wy.final();
    }
};

const TypeSummaryContext = struct {
    pub fn eql(self: TypeSummaryContext, a: TypeSummary, b: TypeSummary) bool {
        _ = self;
        return a.eql(b);
    }

    pub fn hash(self: TypeSummaryContext, key: TypeSummary) u64 {
        _ = self;
        return key.hash();
    }
};

pub const InstanceValue = struct {
    kind: Kind,

    pub const Kind = enum {
        @"enum",
        @"struct",
        @"union",
        @"opaque",
        error_set,

        pub fn name(self: Kind) []const u8 {
            return switch (self) {
                .@"enum" => "Enum instance",
                .@"struct" => "Struct instance",
                .@"union" => "Union instance",
                .@"opaque" => "Opaque instance",
                .error_set => "Error instance",
            };
        }
    };

    fn eql(a: InstanceValue, b: InstanceValue) bool {
        return a.kind == b.kind;
    }

    fn hash(self: InstanceValue) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, self.kind);
        return wy.final();
    }
};

pub const ChildType = union(enum) {
    unknown,
    other,
    primitive: Primitive,
    @"fn",
    fn_returns_type,
    instance: InstanceValue,
    type: TypeValue,

    fn eql(a: ChildType, b: ChildType) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

        return switch (a) {
            .primitive => |a_primitive| a_primitive.eql(b.primitive),
            .type => |a_type| a_type.eql(b.type),
            .instance => |a_instance| a_instance.eql(b.instance),
            else => true,
        };
    }

    fn hash(self: ChildType) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, std.meta.activeTag(self));

        switch (self) {
            .primitive => |primitive| std.hash.autoHash(&wy, primitive.hash()),
            .type => |type_value| std.hash.autoHash(&wy, type_value.hash()),
            .instance => |instance_value| std.hash.autoHash(&wy, instance_value.hash()),
            else => {},
        }

        return wy.final();
    }

    fn fromSummary(type_summary: TypeSummary) ChildType {
        return switch (type_summary) {
            .unknown => .unknown,
            .other => .other,
            .primitive => |primitive| .{ .primitive = primitive },
            .@"fn" => .@"fn",
            .fn_returns_type => .fn_returns_type,
            .instance => |instance_value| .{ .instance = instance_value },
            .type => |type_value| .{ .type = type_value },
            .slice, .array => .other,
        };
    }
};

pub const Slice = struct {
    child_type: ChildType,

    fn eql(a: Slice, b: Slice) bool {
        return a.child_type.eql(b.child_type);
    }

    fn hash(self: Slice) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, self.child_type.hash());
        return wy.final();
    }
};

pub const Array = struct {
    child_type: ChildType,

    fn eql(a: Array, b: Array) bool {
        return a.child_type.eql(b.child_type);
    }

    fn hash(self: Array) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, self.child_type.hash());
        return wy.final();
    }
};

pub const TypeValue = struct {
    kind: Kind,

    pub const unknown: TypeValue = .{ .kind = .unknown };

    pub const Kind = enum {
        unknown,
        primitive,
        @"fn",
        fn_returns_type,
        error_set,
        @"enum",
        @"struct",
        namespace,
        @"union",
        @"opaque",

        pub fn name(self: Kind) []const u8 {
            return switch (self) {
                .unknown => "Type",
                .primitive => "Primitive type",
                .@"fn" => "Function type",
                .fn_returns_type => "Type function type",
                .error_set => "Error",
                .@"enum" => "Enum",
                .@"struct" => "Struct",
                .namespace => "Namespace",
                .@"union" => "Union",
                .@"opaque" => "Opaque",
            };
        }
    };

    fn eql(a: TypeValue, b: TypeValue) bool {
        return a.kind == b.kind;
    }

    fn hash(self: TypeValue) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, self.kind);
        return wy.final();
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

        fn hash(self: Primitive.Number) u64 {
            var wy = std.hash.Wyhash.init(0);
            std.hash.autoHash(&wy, self.name.len);
            wy.update(self.name);
            std.hash.autoHash(&wy, self.kind);
            std.hash.autoHash(&wy, self.bits);
            return wy.final();
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

    fn hash(self: Primitive) u64 {
        var wy = std.hash.Wyhash.init(0);
        std.hash.autoHash(&wy, std.meta.activeTag(self));

        switch (self) {
            .bool => {},
            .number => |number| std.hash.autoHash(&wy, number.hash()),
            .named => |name| {
                std.hash.autoHash(&wy, name.len);
                wy.update(name);
            },
        }

        return wy.final();
    }
};

pub fn deinit(self: *TypeStore, gpa: std.mem.Allocator) void {
    self.summaries.deinit(gpa);
    self.type_id_by_summary.deinit(gpa);
}

pub fn store(
    self: *TypeStore,
    gpa: std.mem.Allocator,
    type_summary: TypeSummary,
) TypeId {
    const zone = tracy.traceNamed(@src(), "TypeStore.store");
    defer zone.end();

    if (self.type_id_by_summary.get(type_summary)) |type_id| return type_id;

    const type_id: TypeId = .fromIndex(self.summaries.items.len);
    self.summaries.append(gpa, type_summary) catch @panic("OOM");
    self.type_id_by_summary.put(gpa, type_summary, type_id) catch @panic("OOM");
    return type_id;
}

pub fn summary(self: *const TypeStore, type_id: TypeId) TypeSummary {
    return self.summaries.items[type_id.toIndex()];
}

pub fn debugPrintSummary(summary_value: TypeSummary) void {
    switch (summary_value) {
        .primitive => |primitive| switch (primitive) {
            .bool => std.debug.print("bool", .{}),
            .number => |number| std.debug.print("{s}", .{number.name}),
            .named => |name| std.debug.print("{s}", .{name}),
        },
        .instance => |instance_value| std.debug.print("{s}", .{instance_value.kind.name()}),
        .type => |type_value| std.debug.print("{s}", .{type_value.kind.name()}),
        .slice => |slice_value| {
            std.debug.print("slice(", .{});
            debugPrintChildType(slice_value.child_type);
            std.debug.print(")", .{});
        },
        .array => |array_value| {
            std.debug.print("array(", .{});
            debugPrintChildType(array_value.child_type);
            std.debug.print(")", .{});
        },
        inline else => |_, tag| std.debug.print("{s}", .{tag.name()}),
    }
}

fn debugPrintChildType(child_type: ChildType) void {
    switch (child_type) {
        .primitive => |primitive| switch (primitive) {
            .bool => std.debug.print("bool", .{}),
            .number => |number| std.debug.print("{s}", .{number.name}),
            .named => |name| std.debug.print("{s}", .{name}),
        },
        .instance => |instance_value| std.debug.print("{s}", .{instance_value.kind.name()}),
        .type => |type_value| std.debug.print("{s}", .{type_value.kind.name()}),
        inline else => |_, tag| std.debug.print("{s}", .{@tagName(tag)}),
    }
}

pub fn summarizeRoot() TypeSummary {
    return .{ .type = .{ .kind = .namespace } };
}

pub fn summarizeFnProto(
    tree: Ast,
    fn_proto: Ast.full.FnProto,
    comptime as_type_value: bool,
) TypeSummary {
    const zone = tracy.traceNamed(@src(), "TypeStore.summarizeFnProto");
    defer zone.end();

    const returns_type = if (fn_proto.ast.return_type.unwrap()) |return_node| returns_type: {
        const unwrapped_return = ast.unwrapNode(tree, return_node, .{});
        break :returns_type ast.isIdentiferKind(tree, unwrapped_return, .type);
    } else false;

    return if (as_type_value)
        .{ .type = .{ .kind = if (returns_type) .fn_returns_type else .@"fn" } }
    else if (returns_type) .fn_returns_type else .@"fn";
}

pub fn summarizeValueNode(
    tree: Ast,
    value_node: Ast.Node.Index,
) ?TypeSummary {
    const zone = tracy.traceNamed(@src(), "TypeStore.summarizeValueNode");
    defer zone.end();

    return summarizeValueExpr(tree, value_node);
}

pub fn summarizeFnReturnType(
    tree: Ast,
    fn_proto: Ast.full.FnProto,
) ?TypeSummary {
    const zone = tracy.traceNamed(@src(), "TypeStore.summarizeFnReturnType");
    defer zone.end();

    const return_type = fn_proto.ast.return_type.unwrap() orelse return null;
    return summarizeTypeNode(tree, return_type);
}

pub fn summarizeTypeNode(
    tree: Ast,
    type_node: Ast.Node.Index,
) TypeSummary {
    const zone = tracy.traceNamed(@src(), "TypeStore.summarizeTypeNode");
    defer zone.end();

    return summarizeTypeExpr(tree, type_node) orelse
        .unknown;
}

fn summarizeDeclType(
    tree: Ast,
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
    tree: Ast,
    type_node: Ast.Node.Index,
) ?TypeSummary {
    const zone = tracy.traceNamed(@src(), "TypeStore.summarizeTypeExpr");
    defer zone.end();

    const node = ast.unwrapNode(tree, type_node, .{
        .unwrap_pointer = false,
    });

    if (tree.fullArrayType(node)) |array_type| {
        return .{
            .array = .{
                .child_type = ChildType.fromSummary(
                    summarizeTypeExpr(tree, array_type.ast.elem_type) orelse .unknown,
                ),
            },
        };
    }

    if (tree.fullPtrType(node)) |ptr_type| {
        if (ptr_type.size == .slice) {
            return .{
                .slice = .{
                    .child_type = ChildType.fromSummary(
                        summarizeTypeExpr(tree, ptr_type.ast.child_type) orelse .unknown,
                    ),
                },
            };
        }

        return summarizeTypeExpr(tree, ptr_type.ast.child_type);
    }

    if (tree.fullSlice(node)) |slice_type| {
        return .{
            .slice = .{
                .child_type = ChildType.fromSummary(
                    summarizeTypeExpr(tree, slice_type.ast.sliced) orelse .unknown,
                ),
            },
        };
    }

    if (tree.nodeTag(node) == .identifier) {
        const name = tree.getNodeSource(node);
        if (primitiveFromName(name)) |primitive| return .{ .primitive = primitive };
        if (std.mem.eql(u8, name, "type")) return .{ .type = .unknown };
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return summarizeFnProto(tree, fn_proto, false);
    }

    if (summarizePtrFnType(tree, node, false)) |ptr_fn_summary| return ptr_fn_summary;

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
        return summarizeContainerDecl(tree, container_decl, .instance);
    }

    switch (tree.nodeTag(node)) {
        .error_set_decl,
        .merge_error_sets,
        => return .{ .type = .{ .kind = .error_set } },
        else => return null,
    }
}

fn summarizeValueExpr(
    tree: Ast,
    value_node: Ast.Node.Index,
) ?TypeSummary {
    const zone = tracy.traceNamed(@src(), "TypeStore.summarizeValueExpr");
    defer zone.end();

    const node = ast.unwrapNode(tree, value_node, .{
        .unwrap_pointer = false,
        .unwrap_optional_unwrap = false,
    });

    if (tree.fullArrayType(node)) |array_type| {
        return .{
            .array = .{
                .child_type = ChildType.fromSummary(
                    summarizeTypeExpr(tree, array_type.ast.elem_type) orelse .unknown,
                ),
            },
        };
    }

    if (tree.fullPtrType(node)) |ptr_type| {
        if (ptr_type.size == .slice) {
            return .{
                .slice = .{
                    .child_type = ChildType.fromSummary(
                        summarizeTypeExpr(tree, ptr_type.ast.child_type) orelse .unknown,
                    ),
                },
            };
        }

        return summarizeValueExpr(tree, ptr_type.ast.child_type);
    }

    if (tree.fullSlice(node)) |slice_type| {
        return .{
            .slice = .{
                .child_type = ChildType.fromSummary(
                    summarizeTypeExpr(tree, slice_type.ast.sliced) orelse .unknown,
                ),
            },
        };
    }

    switch (tree.nodeTag(node)) {
        .identifier => {
            const value = tree.getNodeSource(node);
            if (std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "false")) {
                return .{ .primitive = .bool };
            }
            if (primitiveFromName(value) != null) return .{ .type = .{ .kind = .primitive } };
            if (std.mem.eql(u8, value, "type")) return .{ .type = .unknown };
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
        => return .{ .type = .{ .kind = .error_set } },
        .error_value => return .{ .instance = .{ .kind = .error_set } },
        .builtin_call_two,
        .builtin_call_two_comma,
        .builtin_call,
        .builtin_call_comma,
        => {
            const builtin_name = tree.tokenSlice(tree.nodeMainToken(node));
            if (std.mem.eql(u8, builtin_name, "@import")) return .{ .type = .{ .kind = .namespace } };
            if (std.mem.eql(u8, builtin_name, "@Type") or std.mem.eql(u8, builtin_name, "@TypeOf")) {
                return .{ .type = .unknown };
            }
        },
        else => {},
    }

    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_proto_buffer, node)) |fn_proto| {
        return summarizeFnProto(tree, fn_proto, true);
    }

    if (summarizePtrFnType(tree, node, true)) |ptr_fn_summary| return ptr_fn_summary;

    var container_decl_buffer: [2]Ast.Node.Index = undefined;
    if (tree.fullContainerDecl(&container_decl_buffer, node)) |container_decl| {
        return summarizeContainerDecl(tree, container_decl, .type_value);
    }

    return .unknown;
}

fn summarizePtrFnType(
    tree: Ast,
    node: Ast.Node.Index,
    comptime as_type_value: bool,
) ?TypeSummary {
    const ptr_type = tree.fullPtrType(node) orelse return null;
    var fn_proto_buffer: [1]Ast.Node.Index = undefined;
    const fn_proto = tree.fullFnProto(
        &fn_proto_buffer,
        ptr_type.ast.child_type,
    ) orelse return null;

    return summarizeFnProto(tree, fn_proto, as_type_value);
}

fn summarizeContainerDecl(
    tree: Ast,
    container_decl: Ast.full.ContainerDecl,
    comptime mode: enum { instance, type_value },
) TypeSummary {
    const token_tag = tree.tokenTag(container_decl.ast.main_token);
    return switch (token_tag) {
        .keyword_struct => switch (mode) {
            .instance => if (ast.isContainerNamespace(tree, container_decl)) .{ .type = .{ .kind = .namespace } } else .{ .instance = .{ .kind = .@"struct" } },
            .type_value => .{ .type = .{ .kind = if (ast.isContainerNamespace(tree, container_decl)) .namespace else .@"struct" } },
        },
        .keyword_union => switch (mode) {
            .instance => .{ .instance = .{ .kind = .@"union" } },
            .type_value => .{ .type = .{ .kind = .@"union" } },
        },
        .keyword_opaque => switch (mode) {
            .instance => .{ .instance = .{ .kind = .@"opaque" } },
            .type_value => .{ .type = .{ .kind = .@"opaque" } },
        },
        .keyword_enum => switch (mode) {
            .instance => .{ .instance = .{ .kind = .@"enum" } },
            .type_value => .{ .type = .{ .kind = .@"enum" } },
        },
        inline else => |token| @panic("Unexpected container main token: " ++ @tagName(token)),
    };
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

test "TypeStore.store deduplicates equivalent summaries" {
    var type_store: TypeStore = .empty;
    defer type_store.deinit(std.testing.allocator);

    const first = type_store.store(std.testing.allocator, .{ .primitive = .{
        .number = .{
            .name = "u32",
            .kind = .unsigned_int,
            .bits = 32,
        },
    } });
    const second = type_store.store(std.testing.allocator, .{ .primitive = .{
        .number = .{
            .name = "u32",
            .kind = .unsigned_int,
            .bits = 32,
        },
    } });
    const third = type_store.store(std.testing.allocator, .{ .primitive = .{
        .number = .{
            .name = "u64",
            .kind = .unsigned_int,
            .bits = 64,
        },
    } });

    try std.testing.expectEqual(first, second);
    try std.testing.expect(third != first);
    try std.testing.expectEqual(@as(usize, 2), type_store.summaries.items.len);
}

const Ast = std.zig.Ast;
const ast = @import("../ast.zig");
const std = @import("std");
const tracy = @import("tracy");
