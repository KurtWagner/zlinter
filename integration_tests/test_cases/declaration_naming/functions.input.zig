// Function declarations:
const goodFn = fn () void{};
const GoodFnType: fn () type = undefined;
const Badfn = fn () void{};
const badfnType: fn () type = undefined;

// Function pointers:
const goodFnPtr = *const fn () void{};
const GoodFnPtrType: *const fn () type = undefined;
const BadFnPtr = *const fn () void{};
const badFnPtrType: *const fn () type = undefined;

// Function optionals:
const goodFnPtrOptional: ?*const fn () void = null;
const GoodFnPtrOptionalType: ?*const fn () type = null;
const BadFnPtrOptional: ?*const fn () void = null;
const badFnPtrOptionalType: ?*const fn () type = null;

pub var my_struct_namespace = struct {
    // Some nested examples:
    const goodNestedFn = *const fn () void{};
    const BadNestedFn = *const fn () void{};
};
