# zlinter rules

## `declaration_naming`

Enforces that variable declaration names use consistent naming. For example,
`snake_case` for non-types, `TitleCase` for types and `camelCase` for functions.

**Config options:**

* `exclude_extern`

  * Exclude extern / foreign declarations. An extern declaration refers to a foreign declaration — typically defined outside of Zig, such as in a C library or other system-provided binary. You typically don't want to enforce naming conventions on these declarations.

  * **Default:** `true`

* `exclude_export`

  * Exclude exported declarations. Export makes the symbol visible to external code, such as C or other languages that might link against your Zig code. You may prefer to rely on the naming conventions of the code being linked, in which case, you may set this to true.

  * **Default:** `false`

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

## `field_ordering`

Enforce a consistent, predictable order for fields in structs, enums, and unions.

`field_ordering` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places.

**Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**

**Config options:**

* `union_field_order`

  * Order and severity for union fields. If you're setting this and use tagged unions (e.g., `union(MyEnum)`) then you will also need to set the same order for enums.

  * **Default:** `.{ .order = .alphabetical_ascending, .severity = .warning, }`

* `struct_field_order`

  * Order and severity for struct fields

  * **Default:** `.off`

* `exclude_packed_structs`

  * Whether to check order of packed structs (e.g., `packed struct(u32) { .. }`). You probably never want to enforce order of packed structs, so best to leave as `true` unless you're certain.

  * **Default:** `true`

* `exclude_extern_structs`

  * Whether to check order of extern structs (e.g., `extern struct { .. }`). You probably never want to enforce order of extern structs, so best to leave as `true` unless you're certain.

  * **Default:** `true`

* `enum_field_order`

  * Order and severity for enum fields. If you're setting this and use tagged unions (e.g., `union(MyEnum)`) then you will also need to set the same order for unions.

  * **Default:** `.{ .order = .alphabetical_ascending, .severity = .warning, }`

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

* `exclude_extern`

  * Exclude extern / foreign functions. An extern function refers to a foreign function — typically defined outside of Zig, such as in a C library or other system-provided binary. You typically don't want to enforce naming conventions on these functions.

  * **Default:** `true`

* `exclude_export`

  * Exclude exported functions. Export makes the symbol visible to external code, such as C or other languages that might link against your Zig code. You may prefer to rely on the naming conventions of the code being linked, in which case, you may set this to true.

  * **Default:** `false`

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

* `exclude_extern`

  * Exclude extern / foreign functions. An extern function refers to a foreign function — typically defined outside of Zig, such as in a C library or other system-provided binary. You typically don't want to enforce naming conventions on these functions.

  * **Default:** `true`

* `exclude_export`

  * Exclude exported functions. Export makes the symbol visible to external code, such as C or other languages that might link against your Zig code. You may prefer to rely on the naming conventions of the code being linked, in which case, you may set this to true.

  * **Default:** `false`

## `no_comment_out_code`

Discourage leaving commented-out code in committed files.

**Why?**

Commenting out blocks of old or unused code might seem helpful during development, but leaving them behind creates clutter and confusion over time.

**Problems:**

* Makes files noisy - harder to read and navigate.
* Creates dead code that might be mistakenly reused or assumed to be maintained.
* Can increase merge conflicts and noise in diffs.
* Hides real version history — version control should preserve old code, not your comments!

**What to do instead?**:

* If you don’t need it, delete it — you can always recover it from version control.
* If it’s experimental, keep it on a branch or behind a flag instead.

**Notes:**

* Comments that contain back ticks, like `this("example")` will be ignored
* The heuristic of what looks like code isn't perfect and may have false
negatives (e.g., commenting out struct fields) but will slowly improve
overtime as the linter evolves.

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.warning`

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

## `no_inferred_error_unions`

Disallow using inferred error sets in function return types — always declare them explicitly.

In Zig, when you write `!T` as a return type without an explicit error set
(e.g. `!void`), Zig infers the error set from whatever operations inside the
function can fail.

This is powerful, but it can:

* Make APIs harder to understand - the possible errors aren’t visible at the signature.
* Make refactoring risky - adding or changing a failing operation silently changes the function’s error type.
* Lead to brittle dependencies - downstream callers may break if the inferred error set grows or changes.

The goal of the rule is to keep error contracts clear and stable. If it can fail, say how.

**Config options:**

* `severity`

  * The severity of inferred error unions (off, warning, error).

  * **Default:** `.warning`

* `allow_private`

  * Allow inferred error unions for private functions.

  * **Default:** `true`

* `allow_anyerror`

  * Allow `anyerror` as the explicit error.

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

  * **Default:** `.off`

* `detect_bool_literal`

  * The severity of detecting bool literals (off, warning, error).

  * **Default:** `.warning`

* `exclude_tests`

  * Skip if found within `test { ... }` block.

  * **Default:** `true`

* `exclude_fn_names`

  * Skip if the literal argument is to a function with given name (case-sensitive).

  * **Default:** `&.{ "print", "alloc", "allocWithOptions", "allocWithOptionsRetAddr", "allocSentinel", "alignedAlloc", "allocAdvancedWithRetAddr", "resize", "realloc", "reallocAdvanced", "parseInt", "IntFittingRange", }`

## `no_literal_only_bool_expression`

Disallow boolean expressions that consist only of literal values.

If a boolean expression always evaluates to true or false, the statement is
redundant and likely unintended. Remove it or replace it with a meaningful
condition.

For example,

```zig
// Bad
if (1 == 1) {
  // always true
}

// Bad
if (false) {
  // always false
}

// Ok
while (true) {
   break;
}
```

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.@"error"`

## `no_orelse_unreachable`

Enforces use of `.?` over `orelse unreachable` as `.?` offers comptime checks
as it does not control flow.

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.warning`

## `no_panic`

Enforces that there are no uses of `@panic`.

`@panic` forcibly stops the program at runtime — it should be a last resort.

Panics can be replaced with:

* Proper error handling (error types and try / catch)
* Precondition checks (std.debug.assert) that fail only in debug mode
* Compile-time checks (comptime) when possible

Panics may be useful during early development, but leaving them in shipped code leads to:

* Abrupt crashes that break user trust
* Hard-to-debug failures in production
* Missed opportunities for graceful recovery

By default this will not flag `@panic` found in `test` blocks.

**Good:**

```zig
pub fn divide(x: i32, y: i32) i32 {
  if (y == 0) @panic("Divide by zero!");
  return x / y;
}
```

**Bad:**

```zig
pub fn divide(x: i32, y: i32) !i32 {
  if (y == 0) return error.DivideByZero;
  return x / y;
}
```

**Config options:**

* `severity`

  * The severity of using `@panic` (off, warning, error).

  * **Default:** `.warning`

* `exclude_tests`

  * Skip if found within `test { ... }` block.

  * **Default:** `true`

## `no_swallow_error`

Disallow silently swallowing errors without proper handling or logging.

For example, `catch {}` and `catch unreachable`

**Config options:**

* `detect_catch_unreachable`

  * The severity of detecting `catch unreachable` or `catch { unreachable; } (off, warning, error).

  * **Default:** `.warning`

* `detect_empty_catch`

  * The severity of detecting `catch {}` (off, warning, error).

  * **Default:** `.warning`

* `detect_empty_else`

  * The severity of detecting `else |_| {}` (off, warning, error).

  * **Default:** `.warning`

* `detect_else_unreachable`

  * The severity of detecting `else |_| unreachable` or `else |_| { unreachable; }` (off, warning, error).

  * **Default:** `.warning`

* `exclude_tests`

  * Skip if found within `test { ... }` block.

  * **Default:** `true`

## `no_todo`

Disallows todo comments

`TODO` comments are often used to indicate missing logic, features or the existence
of bugs. While this is useful during development, leaving them untracked can
lead to them being forgotten or not prioritised correctly.

If you must leave a todo comment it's best to include a link to an issue
in your issue tracker so it's visible, prioritized and won't be forgotten.

**Config options:**

* `severity`

  * The severity (off, warning, error).

  * **Default:** `.warning`

* `exclude_if_contains_issue_number`

  * Exclude todo comments that contain a `#[0-9]+` in a word token or nested in the todo suffix. For example, `// TODO(http://my-issue-tracker.com/10): <info>` or `// TODO: Fix http://my-issue-tracker.com/10`

  * **Default:** `true`

* `exclude_if_contains_url`

  * Exclude todo comments that contain a url in a word token or nested in the todo suffix. For example, `// TODO(http://my-issue-tracker.com/10): <info>` or `// TODO: Fix http://my-issue-tracker.com/10`

  * **Default:** `true`

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

`no_unused` supports auto fixes with the `--fix` flag. It may take multiple runs with `--fix` to fix all places.

**Auto fixing is an experimental feature so only use it if you use source control - always back up your code first!**

**Config options:**

* `container_declaration`

  * The severity for container declarations that are unused (off, warning, error).

  * **Default:** `.warning`

## `require_doc_comment`

Require doc comments for all public functions, types, and constants.

Unless you're maintaining an open API used by other projects this rule is more than
likely unnecessary, and in some cases, can encourage avoidable noise on
otherwise simple APIs.

**Config options:**

* `public_severity`

  * The severity when missing doc comments on public declarations (off, warning, error).

  * **Default:** `.warning`

* `private_severity`

  * The severity when missing doc comments on private declarations (off, warning, error).

  * **Default:** `.off`

* `file_severity`

  * The severity when missing doc comments on top of the file (off, warning, error).

  * **Default:** `.off`

## `switch_case_ordering`

Enforces an order of values in `switch` statements.

**Config options:**

* `else_is_last`

  * The severity for when `else` is not last in a `switch` (off, warning, error).

  * **Default:** `.warning`
