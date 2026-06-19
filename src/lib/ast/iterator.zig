/// Iterator over direct child nodes of an AST node.
///
/// Code in here is adapted from ZLS.
///
/// ZLS license:
///
/// MIT License
///
/// Copyright (c) ZLS contributors
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
/// SOFTWARE.
pub const ChildIterator = union(enum) {
    array: [5]Ast.Node.OptionalIndex,
    sub_range: struct {
        prefix: Ast.Node.OptionalIndex = .none,
        items: Ast.Node.SubRange,
        suffix: [2]Ast.Node.OptionalIndex = @splat(.none),
    },
    fn_proto: struct {
        node: Ast.Node.Index,
        param_i: usize = 0,
        done_params: bool = false,
    },
    @"asm": struct {
        template: Ast.Node.OptionalIndex,
        items: Ast.Node.SubRange,
        clobbers: Ast.Node.OptionalIndex,
    },

    pub fn init(tree: Ast, node: Ast.Node.Index) ChildIterator {
        return switch (tree.nodeTag(node)) {
            .bool_not,
            .negation,
            .bit_not,
            .negation_wrap,
            .address_of,
            .@"try",
            .optional_type,
            .deref,
            .@"suspend",
            .@"resume",
            .@"comptime",
            .@"nosuspend",
            .@"defer",
            => .initArray(.{tree.nodeData(node).node}),
            .@"return" => .initArray(.{tree.nodeData(node).opt_node}),

            .@"catch",
            .equal_equal,
            .bang_equal,
            .less_than,
            .greater_than,
            .less_or_equal,
            .greater_or_equal,
            .assign_mul,
            .assign_div,
            .assign_mod,
            .assign_add,
            .assign_sub,
            .assign_shl,
            .assign_shl_sat,
            .assign_shr,
            .assign_bit_and,
            .assign_bit_xor,
            .assign_bit_or,
            .assign_mul_wrap,
            .assign_add_wrap,
            .assign_sub_wrap,
            .assign_mul_sat,
            .assign_add_sat,
            .assign_sub_sat,
            .assign,
            .merge_error_sets,
            .mul,
            .div,
            .mod,
            .mul_wrap,
            .mul_sat,
            .add,
            .sub,
            .array_cat,
            .add_wrap,
            .sub_wrap,
            .add_sat,
            .sub_sat,
            .shl,
            .shl_sat,
            .shr,
            .bit_and,
            .bit_xor,
            .bit_or,
            .@"orelse",
            .bool_and,
            .bool_or,
            .array_type,
            .array_access,
            .array_init_one,
            .array_init_one_comma,
            .switch_range,
            .fn_decl,
            .container_field_align,
            .error_union,
            => {
                const lhs, const rhs = tree.nodeData(node).node_and_node;
                return .initArray(.{ lhs, rhs });
            },

            .call_one,
            .call_one_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .container_field_init,
            .for_range,
            => {
                const lhs, const opt_rhs = tree.nodeData(node).node_and_opt_node;
                return .initArray(.{ lhs, opt_rhs });
            },

            .array_init_dot_two,
            .array_init_dot_two_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            .block_two,
            .block_two_semicolon,
            .builtin_call_two,
            .builtin_call_two_comma,
            .container_decl_two,
            .container_decl_two_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            => {
                const opt_lhs, const opt_rhs = tree.nodeData(node).opt_node_and_opt_node;
                return .initArray(.{ opt_lhs, opt_rhs });
            },

            .field_access,
            .unwrap_optional,
            .grouped_expression,
            .asm_simple,
            => .initArray(.{tree.nodeData(node).node_and_token[0]}),
            .test_decl => .initArray(.{tree.nodeData(node).opt_token_and_node[1]}),
            .@"errdefer" => .initArray(.{tree.nodeData(node).node}),
            .anyframe_type => .initArray(.{tree.nodeData(node).token_and_node[1]}),
            .@"break", .@"continue" => .initArray(.{tree.nodeData(node).opt_token_and_opt_node[1]}),

            .root => switch (tree.mode) {
                .zig => .{ .sub_range = .{ .items = tree.nodeData(.root).extra_range } },
                .zon => .{ .array = .{ tree.nodeData(.root).node.toOptional(), .none, .none, .none, .none } },
            },

            .array_init_dot,
            .array_init_dot_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .builtin_call,
            .builtin_call_comma,
            .container_decl,
            .container_decl_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .block,
            .block_semicolon,
            => .{ .sub_range = .{
                .items = tree.nodeData(node).extra_range,
            } },

            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = tree.fullVarDecl(node).?.ast;
                return .initArray(.{
                    var_decl.type_node,
                    var_decl.align_node,
                    var_decl.addrspace_node,
                    var_decl.section_node,
                    var_decl.init_node,
                });
            },

            .assign_destructure => {
                const extra_index, const value_expr = tree.nodeData(node).extra_and_node;
                const variable_count = tree.extra_data[@intFromEnum(extra_index)];
                const sub_range_start: Ast.ExtraIndex = @enumFromInt(@intFromEnum(extra_index) + 1);
                const sub_range_end: Ast.ExtraIndex = @enumFromInt(@intFromEnum(sub_range_start) + variable_count);
                return .{ .sub_range = .{
                    .items = .{ .start = sub_range_start, .end = sub_range_end },
                    .suffix = .{ value_expr.toOptional(), .none },
                } };
            },

            .array_type_sentinel => {
                const array_type = tree.arrayTypeSentinel(node).ast;
                return .initArray(.{
                    array_type.elem_count,
                    array_type.sentinel,
                    array_type.elem_type,
                });
            },

            .ptr_type_aligned,
            .ptr_type_sentinel,
            .ptr_type,
            => {
                const ptr_type = tree.fullPtrType(node).?.ast;
                std.debug.assert(ptr_type.bit_range_start == .none);
                std.debug.assert(ptr_type.bit_range_end == .none);
                return .initArray(.{
                    ptr_type.sentinel,
                    ptr_type.align_node,
                    ptr_type.addrspace_node,
                    ptr_type.child_type,
                });
            },
            .ptr_type_bit_range => {
                const ptr_type = tree.ptrTypeBitRange(node);
                std.debug.assert(ptr_type.size == .one);
                std.debug.assert(ptr_type.ast.sentinel == .none);
                std.debug.assert(ptr_type.ast.bit_range_start != .none);
                std.debug.assert(ptr_type.ast.bit_range_end != .none);
                return .initArray(.{
                    ptr_type.ast.align_node,
                    ptr_type.ast.bit_range_start,
                    ptr_type.ast.bit_range_end,
                    ptr_type.ast.addrspace_node,
                    ptr_type.ast.child_type,
                });
            },

            .slice_open,
            .slice,
            .slice_sentinel,
            => {
                const slice = tree.fullSlice(node).?;
                return .initArray(.{
                    slice.ast.sliced,
                    slice.ast.start,
                    slice.ast.end,
                    slice.ast.sentinel,
                });
            },

            .array_init,
            .array_init_comma,
            .struct_init,
            .struct_init_comma,
            .call,
            .call_comma,
            .@"switch",
            .switch_comma,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                const prefix, const extra_index = tree.nodeData(node).node_and_extra;
                return .{ .sub_range = .{
                    .prefix = prefix.toOptional(),
                    .items = tree.extraData(extra_index, Ast.Node.SubRange),
                } };
            },

            .switch_case_one, .switch_case_inline_one => {
                const first_value, const target_expr = tree.nodeData(node).opt_node_and_node;
                return .initArray(.{ first_value, target_expr });
            },
            .switch_case,
            .switch_case_inline,
            => {
                const extra_index, const target_expr = tree.nodeData(node).extra_and_node;
                return .{ .sub_range = .{
                    .items = tree.extraData(extra_index, Ast.Node.SubRange),
                    .suffix = .{ target_expr.toOptional(), .none },
                } };
            },

            .while_simple,
            .while_cont,
            .@"while",
            => {
                const while_ast = tree.fullWhile(node).?.ast;
                return .initArray(.{
                    while_ast.cond_expr,
                    while_ast.cont_expr,
                    while_ast.then_expr,
                    while_ast.else_expr,
                });
            },
            .for_simple => {
                const input, const then_expr = tree.nodeData(node).node_and_node;
                return .initArray(.{ input, then_expr });
            },
            .@"for" => {
                const extra_index, const extra = tree.nodeData(node).@"for";
                const then_expr: Ast.Node.Index = @enumFromInt(tree.extra_data[@intFromEnum(extra_index) + extra.inputs]);
                const else_expr: Ast.Node.OptionalIndex = if (extra.has_else) @enumFromInt(tree.extra_data[@intFromEnum(extra_index) + extra.inputs + 1]) else .none;
                return .{ .sub_range = .{
                    .items = .{ .start = extra_index, .end = @enumFromInt(@intFromEnum(extra_index) + extra.inputs) },
                    .suffix = .{ then_expr.toOptional(), else_expr },
                } };
            },

            .@"if",
            .if_simple,
            => {
                const if_ast = tree.fullIf(node).?.ast;
                return .initArray(.{
                    if_ast.cond_expr,
                    if_ast.then_expr,
                    if_ast.else_expr,
                });
            },
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => {
                return .{
                    .fn_proto = .{
                        .node = node,
                    },
                };
            },

            .container_field => {
                const field = tree.containerField(node).ast;
                return .initArray(.{
                    field.type_expr,
                    field.align_expr,
                    field.value_expr,
                });
            },

            .@"asm" => {
                const template, const extra_index = tree.nodeData(node).node_and_extra;
                const extra = tree.extraData(extra_index, Ast.Node.Asm);
                return .{ .@"asm" = .{
                    .template = template.toOptional(),
                    .items = .{ .start = extra.items_start, .end = extra.items_end },
                    .clobbers = extra.clobbers,
                } };
            },

            .asm_output,
            .asm_input,
            => unreachable,

            .anyframe_literal,
            .char_literal,
            .number_literal,
            .unreachable_literal,
            .identifier,
            .enum_literal,
            .string_literal,
            .multiline_string_literal,
            .error_set_decl,
            .error_value,
            => .{ .array = @splat(.none) },
        };
    }

    pub fn next(it: *ChildIterator, tree: Ast) ?Ast.Node.Index {
        sw: switch (it.*) {
            .array => |*array| {
                const result = array[0].unwrap() orelse return null;
                @memmove(array[0 .. array.len - 1], array[1..]);
                array[array.len - 1] = .none;
                return result;
            },
            .sub_range => |*sub_range| {
                if (sub_range.prefix.unwrap()) |result| {
                    sub_range.prefix = .none;
                    return result;
                }
                const items = tree.extraDataSlice(sub_range.items, Ast.Node.Index);
                if (items.len > 0) {
                    defer sub_range.items.start = @enumFromInt(@intFromEnum(sub_range.items.start) + 1);
                    return items[0];
                }
                const first = sub_range.suffix[0].unwrap() orelse return null;
                sub_range.suffix[0] = sub_range.suffix[1];
                sub_range.suffix[1] = .none;
                return first;
            },
            .fn_proto => |*fn_proto| {
                if (!fn_proto.done_params) {
                    var buffer: [1]Ast.Node.Index = undefined;
                    const fn_full = tree.fullFnProto(&buffer, fn_proto.node).?;
                    while (fn_proto.param_i < fn_full.ast.params.len) {
                        const maybe_param = fn_full.ast.params[fn_proto.param_i];
                        fn_proto.param_i += 1;

                        if (@intFromEnum(maybe_param) >= tree.nodes.len) continue;
                        if (maybe_param == .root) continue;
                        return maybe_param;
                    }
                    fn_proto.done_params = true;

                    it.* = .initArray(.{
                        fn_full.ast.align_expr,
                        fn_full.ast.addrspace_expr,
                        fn_full.ast.section_expr,
                        fn_full.ast.callconv_expr,
                        fn_full.ast.return_type,
                    });
                    continue :sw it.*;
                }
                return null;
            },
            .@"asm" => |*asm_state| {
                @branchHint(.unlikely);

                if (asm_state.template.unwrap()) |template| {
                    asm_state.template = .none;
                    return template;
                }
                const items = tree.extraDataSlice(asm_state.items, Ast.Node.Index);

                var i: usize = 0;
                defer asm_state.items.start = @enumFromInt(@intFromEnum(asm_state.items.start) + i);
                while (i < items.len) {
                    defer i += 1;
                    switch (tree.nodeTag(items[i])) {
                        .asm_output => {
                            const output_node = items[i];
                            const has_arrow = tree.tokenTag(tree.nodeMainToken(output_node) + 4) == .arrow;
                            if (!has_arrow) continue;
                            const lhs = tree.nodeData(output_node).opt_node_and_token[0].unwrap() orelse continue;
                            return lhs;
                        },
                        .asm_input => {
                            const input_node = items[i];
                            return tree.nodeData(input_node).node_and_token[0];
                        },
                        else => unreachable,
                    }
                }

                if (asm_state.clobbers.unwrap()) |clobbers| {
                    asm_state.clobbers = .none;
                    return clobbers;
                }

                return null;
            },
        }
    }

    fn initArray(tuple: anytype) ChildIterator {
        var array: @FieldType(ChildIterator, "array") = @splat(.none);
        comptime std.debug.assert(tuple.len <= array.len);
        var i: usize = 0;
        inline for (tuple) |item| {
            switch (@TypeOf(item)) {
                Ast.Node.OptionalIndex => {
                    if (item != .none) {
                        array[i] = item;
                        i += 1;
                    }
                },
                Ast.Node.Index => {
                    std.debug.assert(item != .root);
                    array[i] = item.toOptional();
                    i += 1;
                },
                else => comptime unreachable,
            }
        }
        return .{ .array = array };
    }
};

pub fn nodeChildrenAlloc(
    gpa: std.mem.Allocator,
    tree: Ast,
    node: Ast.Node.Index,
) error{OutOfMemory}![]Ast.Node.Index {
    const zone = tracy.traceNamed(@src(), "ast.nodeChildrenAlloc");
    defer zone.end();

    var children: std.ArrayList(Ast.Node.Index) = .empty;
    defer children.deinit(gpa);

    var it = ChildIterator.init(tree, node);
    while (it.next(tree)) |child_node| {
        std.debug.assert(child_node != .root);
        try children.append(gpa, child_node);
    }

    return children.toOwnedSlice(gpa);
}

const std = @import("std");
const Ast = std.zig.Ast;
const tracy = @import("tracy");
