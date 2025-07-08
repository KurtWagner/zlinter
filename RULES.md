# zlinter rules

## `declaration_naming`

Enforces that variable declaration names use consistent naming. For example,
`snake_case` for non-types, `TitleCase` for types and `camelCase` for functions.

**Config options:**

* `var_decl`

  * Style and severity for declarations with `const` mutability.

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `const_decl`

  * Style and severity for declarations with `var` mutability.

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `decl_that_is_type`

  * Style and severity for type declarations.

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

* `decl_that_is_namespace`

  * Style and severity for namespace declarations.

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `decl_that_is_fn`

  * Style and severity for non-type function declarations.

  * **Default:** `.{ .style = .camel_case, .severity = .@"error", }`

* `decl_that_is_type_fn`

  * Style and severity type function declarations.

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

## `field_naming`

Enforces a consistent naming convention for fields in containers. For
example, `struct`, `enum`, `union`, `opaque` and `error`.

**Config options:**

* `error_field`

  * Style and severity for errors defined within an `error { ... }` container

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

* `enum_field`

  * Style and severity for enum values defined within an `enum { ... }` container

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `struct_field`

  * Style and severity for struct fields defined within a `struct { ... }` container

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `struct_field_that_is_type`

  * Like `struct_field` but for fields with type `type`

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

* `struct_field_that_is_namespace`

  * Like `struct_field` but for fields with a namespace type

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `struct_field_that_is_fn`

  * Like `struct_field` but for fields with a callable/function type

  * **Default:** `.{ .style = .camel_case, .severity = .@"error", }`

* `struct_field_that_is_type_fn`

  * Like `struct_field_that_is_fn` but the callable/function returns a `type`

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

* `union_field`

  * Style and severity for union fields defined within a `union { ... }` block

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

## `file_naming`

Enforces a consistent naming convention for files. For example, `TitleCase`
for implicit structs and `snake_case` for namespaces.

**Config options:**

* `file_namespace`

  * Style and severity for a file that is a namespace (i.e., does not have root container fields)

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `file_struct`

  * Style and severity for a file that is a struct (i.e., has root container fields)

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

## `function_naming`

Enforces consistent naming of functions. For example, `TitleCase` for functions
that return types and `camelCase` for others.

**Config options:**

* `function`

  * Style and severity for non-type functions

  * **Default:** `.{ .style = .camel_case, .severity = .@"error", }`

* `function_that_returns_type`

  * Style and severity for type functions

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

* `function_arg`

  * Style and severity for standard function arg

  * **Default:** `.{ .style = .snake_case, .severity = .@"error", }`

* `function_arg_that_is_type`

  * Style and severity for type function arg

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

* `function_arg_that_is_fn`

  * Style and severity for non-type function function arg

  * **Default:** `.{ .style = .camel_case, .severity = .@"error", }`

* `function_arg_that_is_type_fn`

  * Style and severity for type function function arg

  * **Default:** `.{ .style = .title_case, .severity = .@"error", }`

## `max_positional_args`

Enforces that a function does not define too many positional arguments.

Keeping positional argument lists short improves readability and encourages
concise designs.

If the function is doing too many things, consider splitting it up
into smaller more focused functions. Alternatively, accept a struct with
appropriate defaults.

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.warning`

* `max`

  * The max number of positional arguments. Functions with more than this many arguments will fail the rule.

  * **Default:** `5`

## `no_deprecated`

Enforces that references aren't deprecated (i.e., doc commented with `Deprecated:`)

If you're indefinitely targetting fixed versions of a dependency or zig
then using deprecated items may not be a big deal. Although, it's still
worth undertsanding why they're deprecated, as there may be risks associated
with use.

**Config options:**

* `severity`

  * The severity of deprecations (off, warning, error).

  * **Default:** `.warning`

## `no_hidden_allocations`

Avoid encapsulating hidden heap allocations inside functions without
requiring the caller to pass an allocator.

The caller should decide where and when to allocate not the callee.

**Config options:**

* `severity`

  * The severity of hidden allocations (off, warning, error).

  * **Default:** `.warning`

* `detect_allocators`

  * What kinds of allocators to detect.

  * **Default:** `&.{ .page_allocator, .c_allocator, .general_purpose_allocator, .debug_allocator, }`

* `exclude_tests`

  * Skip if found within `test { ... }` block.

  * **Default:** `true`

## `no_literal_args`

Disallow passing primitive literal numbers and booleans directly as function arguments.

Passing literal `1`, `0`, `true`, or `false` directly to a function is ambiguous.

These magic literals don’t explain what they mean. Consider using named constants or if you're the owner of the API and there's multiple arguments, consider introducing a struct argument

**Config options:**

* `detect_char_literal`

  * The severity of detecting char literals (off, warning, error).

  * **Default:** `.off`

* `detect_string_literal`

  * The severity of detecting string literals (off, warning, error).

  * **Default:** `.off`

* `detect_number_literal`

  * The severity of detecting number literals (off, warning, error).

  * **Default:** `.warning`

* `detect_bool_literal`

  * The severity of detecting bool literals (off, warning, error).

  * **Default:** `.warning`

* `exclude_tests`

  * Skip if found within `test { ... }` block.

  * **Default:** `true`

* `exclude_fn_names`

  * Skip if the literal argument is to a function with given name (case-sensitive).

  * **Default:** `&.{ "print", "alloc", "allocWithOptions", "allocWithOptionsRetAddr", "allocSentinel", "alignedAlloc", "allocAdvancedWithRetAddr", "resize", "realloc", "reallocAdvanced", "parseInt", "IntFittingRange", }`

## `no_orelse_unreachable`

Enforces use of `.?` over `orelse unreachable` as `.?` offers comptime checks
as it does not control flow.

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.warning`

## `no_undefined`

Enforces no uses of `undefined`. There are some valid use case, in which
case uses should disable the line with an explanation.

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.warning`

* `exclude_in_fn`

  * Skip if found in a function call (case-insenstive).

  * **Default:** `&.{"deinit"}`

* `exclude_tests`

  * Skip if found within `test { ... }` block.

  * **Default:** `true`

* `exclude_var_decl_name_equals`

  * Skips var declarations that name equals (case-insensitive, for `var`, not `const`).

  * **Default:** `&.{}`

* `exclude_var_decl_name_ends_with`

  * Skips var declarations that name ends in (case-insensitive, for `var`, not `const`).

  * **Default:** `&.{ "memory", "mem", "buffer", "buf", "buff", }`

## `no_unused`

Enforces that container declarations are referenced.

**Config options:**

* `container_declaration`

  * The severity for container declarations that are unused (off, warning, error).

  * **Default:** `.warning`

## `switch_case_ordering`

Enforces an order of values in `switch` statements.

**Config options:**

* `else_is_last`

  * The severity for when `else` is not last in a `switch` (off, warning, error).

  * **Default:** `.warning`
