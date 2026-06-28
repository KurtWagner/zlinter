// Function declarations:
const goodFn = fn () void{};
var GoodFnType: fn () type = undefined;
const Badfn = fn () void{};
var badfnType: fn () type = undefined;

// Function pointers:
var goodFnPtrWithTypeNode: *const fn () void = undefined;
var GoodFnPtrTypeWithTypeNode: *const fn () type = undefined;
var BadFnPtrWithTypeNode: *const fn () void = undefined;
var bad_fn_ptr_with_type_node: *const fn () void = undefined;
var badFnPtrTypeWithTypeNode: *const fn () type = undefined;
var bad_fn_ptr_type_with_type_node: *const fn () type = undefined;

const goodFnPtrWithInitNode = &noop;
const GoodFnPtrTypeWithInitNode = &GiveType;
const BadFnPtrWithInitNode = &noop;
const bad_fn_ptr_with_init_node = &noop;
const badFnPtrTypeWithInitNode = &GiveType;
const bad_fn_ptr_type_with_init_node = &GiveType;

fn noop() void {
    std.debug.assert(1 == 1);
}

fn GiveType() type {
    return u32;
}

// Function optionals:
const goodFnPtrOptional: ?*const fn () void = null;
const GoodFnPtrOptionalType: ?*const fn () type = null;
const BadFnPtrOptional: ?*const fn () void = null;
const badFnPtrOptionalType: ?*const fn () type = null;

pub var my_struct_namespace = struct {
    // Some nested examples:
    var goodNestedFn: *const fn () void = undefined;
    var BadNestedFn: *const fn () void = undefined;
};

const std = @import("std");
