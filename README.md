<img align="left" width="64" height="64" src="icon_128.png" alt="Zlinter icon">

# Zlinter - Linter for Zig

An extendable and customizable **Zig linter** that is integrated and built from within your own `build.zig`.

![Screenshot](./screenshot.png)

## Table of contents

* [Background](#background)
* [Versioning](#versioning)
* [Features](#features)
* [Getting started](#getting-started)
* [Configure](#configure)
  * [Project config](#project-config)
  * [Disable with comments](#disable-with-comments)
* [Rules](#rules)
  * [Builtin rules](#builtin-rules)
    * [no_deprecated](#no_deprecated)
    * [no_unused](#no_unused)
    * [no_orelse_unreachable](#no_orelse_unreachable)
    * [function_naming](#function_naming)
    * [declaration_naming](#declaration_naming)
    * [field_naming](#field_naming)
    * [file_naming](#file_naming)
    * [switch_case_ordering](#switch_case_ordering)
  * [Custom rules](#custom-rules)
* [For contributors](#for-contributors)
  * [Contributions](#contributions)
  * [Run tests](#run-tests)
  * [Run on self](#run-on-self)

## Background

This was written to be used across my personal projects and experiments. I'm opening it up incase it's more generally useful, and happy to let it organically evolve around needs, if there's value in doing so.

It uses [`zls`](https://github.com/zigtools/zls) (an awesome project) and `std.zig` to build and analyze zig source files.

## Versioning

`zlinter` will:

* follow the same semantic versioning as `zig`;
* use branch `master` for `zig` `master` releases; and
* use branch `0.14.x` for `zig` `0.14.x` releases.

This may change, especially when `zig` is "stable" at `1.x`.

## Features

* [x] Integrates into your `build.zig`
* [x] Builtin rules (e.g., [`no_deprecated`](#no_deprecated) and [`field_naming`](#field_naming))
* [x] Custom rules (e.g., if your project has bespoke rules you need to follow)
* [x] Per rule configurability (e.g., deprecations as warnings)
* [ ] Interchangeable result formatters (e.g., json, checkstyle)

## Getting started

1. Save dependency to your zig project:

    ```shell
    # For 0.14.x
    zig fetch --save git+https://github.com/kurtwagner/zlinter#0.14.x

    # OR
    
    # For master (0.15.x-dev)
    zig fetch --save git+https://github.com/kurtwagner/zlinter#master
    ```

1. Configure `lint` step in your `build.zig`:

    ```zig
    const zlinter = @import("zlinter");
    // ...
    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{});

        // FYI: You don't have to add all builtin rules
        try builder.addRule(.{ .builtin = .field_naming }, .{});
        try builder.addRule(.{ .builtin = .declaration_naming }, .{});
        try builder.addRule(.{ .builtin = .function_naming }, .{});
        try builder.addRule(.{ .builtin = .file_naming }, .{});
        try builder.addRule(.{ .builtin = .no_unused }, .{});
        try builder.addRule(.{ .builtin = .no_deprecation }, .{});
        try builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        try builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        break :step try builder.build();
    });
    ```

1. Run linter:

    ```shell
    zig build lint

    // OR be specific with paths
    zig build lint -- src/ file.zig
    ```

## Configure

### Project config

`addRule` accepts an anonymous struct representing the `Config` of rule being added. For example,

```zig
try builder.addRule(.{ .builtin = .field_naming }, .{
  .enum_field = .{ .style = .snake_case, .severity = .warning },
  .union_field = .off,
  .struct_field_that_is_type = .{ .style = .title_case, .severity = .@"error" },
  .struct_field_that_is_fn = .{ .style = .camel_case, .severity = .@"error" },
});
try builder.addRule(.{ .builtin = .no_deprecation }, .{
  .severity = .warning,
});
```

where `Config` struct are found in the rule source files [`no_deprecation.Config`](./src/rules/no_deprecation.zig) and [`field_naming.Config`](./src/rules/field_naming.zig).

### Disable with comments

#### `zlinter-disable-next-line [rule_1] [rule_n] [- comment]`

Disable all rules or an explicit set of rules for the next source code line. For example,

```zig
// zlinter-disable-next-line no_deprecation - not updating so safe
const a = this.is.deprecated();
```

#### `zlinter-disable-current-line [rule_1] [rule_n] [- comment]`

Disable all rules or an explicit set of rules for the current source code line. For example,

```zig
const a = this.is.deprecated(); // zlinter-disable-current-line
```

## Rules

### Builtin rules

> [!NOTE]  
> :wrench: **[Experimental]** The wrench indicates that some problems reported by this rule can be automatically fixed with
> the `--fix` option. Please only use this option if you use source control. This
> is also subject to change. For now it simply uses text based patches but
> perhaps an AST or token based approach would be better. For now, it's best to
> see this as experimental, and to apply caution appropriately.

#### `no_deprecated`

* [Source code](./src/rules/no_deprecation.zig)

Enforces that there are no references to fields or functions that are
documented as deprecated.

For example,

```zig
/// Deprecated: Use `y` instead
pub const x = 10;

// ...
pub const z = x + 10; // <---- Problem
```

##### When not to use

If you're targetting fixed versions of a dependency or zig then using deprecated
fields and functions is not a huge deal. Although, still worth undertsanding why
they're deprecated, as there may be risks associated with use.

#### `function_naming`

* [Source code](./src/rules/function_naming.zig)

Enforces that functions have consistent naming. The default is that functions use `camelCase` unless they return a type, in which case they are `TitleCase`. This can be changed through the rules configuration.

For example,

```zig
// Ok:
fn goodFn() void {}
fn GoodFn() type {}

// Not ok:
fn bad_fn() void {}
fn BadFn() void {}
```

#### `declaration_naming`

* [Source code](./src/rules/declaration_naming.zig)

Enforces that declarations have consistent naming. Whether they're a `type` or callable may change the naming convention.

For example, the defaults

```zig
const camelCaseFn = const * fn() void {};
const TitleCaseType = u32;
const snake_case_other: u32 = 10;
```

#### `field_naming`

* [Source code](./src/rules/field_naming.zig)

Enforces that fields in `struct {}`, `error {}`, `union {}`, `enum {}` and `opaque {}` containers have consistent naming.

#### `file_naming`

* [Source code](./src/rules/file_naming.zig)

Enforces that file name containers and structs have consistent naming. The default is that namespaces are `snake_case` and root struct files are `TitleCase`.

For example, the defaults:

```zig
//! MyStruct.zig
name: [] const u8

//! my_namespace.zig
const MyStruct = struct {
  name: [] const u8,
};
```

#### `switch_case_ordering`

Enforces a specific ordering for switch statement cases. For example,
by default, it'll warn if `else` is not the last condition (similar to an `if-else-if-else` statement).

#### `no_unused`

* :wrench:
* [Source code](./src/rules/no_unused.zig)

Enforces that container declarations are used.

For example,

```zig
// Ok:
const used = @import("dep");

pub fn ok() void {
    used.ok();
}


// Not ok:
const not_used = @import("dep");
```

#### `no_orelse_unreachable`

Prefer `.?` over `orelse unreachable` as it offers comptime checks, where as, `orelse` controls flow and is runtime.

```zig
// prefer
const a = b.?;

// over
const a = b orelse unreachable;
```

### Custom rules

Bespoke rules can be added to your project. For example, maybe you really don't like cats, and refuse to let any `cats` exist in any identifier. See example rule [`no_cats`](./integration_tests/src/no_cats.zig), which is then integrated like builtin rules in your `build.zig`:

```zig
builder.addRule(b, .{ 
  .custom = .{
    .name = "no_cats",
    .path = "src/no_cats.zig",
  },
}, .{});
```

## For contributors

### Contributions

Contributions and new rules or formatters are very welcome.

* Rules are per project configurable so I don't see any problems if new opinionated ones are added (assuming they're not completely bespoke); perhaps one day there will be a "default" or "recommend" configuration.
* I'm not a zig expert so I'm 100% to learning through pull requests that improve the health of the project.

### Run tests

Unit tests:

```shell
zig build unit-test
```

Integration tests:

```shell
zig build integration-test
```

All tests:

```shell
zig build test
```

### Run on self

```shell
zig build lint -- src/ *.zig
```
