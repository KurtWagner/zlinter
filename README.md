<img align="left" width="64" height="64" src="icon_128.png" alt="Zlinter icon">

# Zlinter - Linter for Zig

> [!IMPORTANT]
> **2025-07-03:** `zlinter` is new (aka unstable) so it may
>
> 1. make breaking changes between commits while it finds its footing; and
> 2. not work completely as documented or expected
>
> Please don't hesitate to help improve `zlinter` by reporting issues and contributing improvements.

[![linux](https://github.com/KurtWagner/zlinter/actions/workflows/linux.yml/badge.svg?branch=0.14.x)](https://github.com/KurtWagner/zlinter/actions/workflows/linux.yml)
[![windows](https://github.com/KurtWagner/zlinter/actions/workflows/windows.yml/badge.svg?branch=0.14.x)](https://github.com/KurtWagner/zlinter/actions/workflows/windows.yml)

An extendable and customizable **Zig linter** that is integrated from source into your `build.zig`.

![Screenshot](./screenshot.png)

## Table of contents

* [Background](#background)
* [Versioning](#versioning)
* [Features](#features)
* [Getting started](#getting-started)
* [Configure](#configure)
  * [Paths](#configure-paths)
  * [Rules](#configure-rules)
  * [Disable with comments](#disable-with-comments)
  * [Command line args](#command-line-args)
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
  * [Run on self](#run-lint-on-self)

## Background

`zlinter` was written to be used across my personal projects. The main motivation was to have it integrated from source through a build step so that it can be

1. customized at build time (e.g., byo rules); and
2. versioned with your projects source control (no separate binary to juggle)

I'm opening it up incase it's more generally useful, and happy to let it
organically evolve around needs, if there's value in doing so.

It uses [`zls`](https://github.com/zigtools/zls) (an awesome project, go check it out if you haven't already) and `std.zig` to build and analyze zig source files.

## Versioning

`zlinter` will:

* follow the same semantic versioning as `zig`;
* use branch `master` for `zig` `master` releases; and
* use branch `0.14.x` for `zig` `0.14.x` releases.

This may change, especially when `zig` is "stable" at `1.x`. If you have opinions on this, feel free to comment on [#20](https://github.com/KurtWagner/zlinter/issues/20).

## Features

* [x] [Integrates from source into your `build.zig`](#getting-started)
* [x] [Builtin rules](#builtin-rules) (e.g., [`no_deprecated`](#no_deprecated) and [`field_naming`](#field_naming))
* [x] [Custom / BYO rules](#custom-rules) (e.g., if your project has bespoke rules you need to follow)
* [x] [Per rule configurability](#configure-rules) (e.g., deprecations as warnings)
* [ ] Interchangeable result formatters (e.g., json, checkstyle)

## Getting started

`zlinter` is not a standalone binary - it's built into your projects `build.zig`.
This makes it flexible to each projects needs. Simply add the dependency and
hook it up to a build step, like `zig build lint`:

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
        try builder.addRule(.{ .builtin = .field_naming }, .{});
        try builder.addRule(.{ .builtin = .declaration_naming }, .{});
        try builder.addRule(.{ .builtin = .function_naming }, .{});
        try builder.addRule(.{ .builtin = .file_naming }, .{});
        try builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        try builder.addRule(.{ .builtin = .no_unused }, .{});
        try builder.addRule(.{ .builtin = .no_deprecated }, .{});
        try builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
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

### Configure paths

The builder used in `build.zig` has a method `addPaths`, which can be used to
add included and excluded paths. For example,

```zig
try builder.addPaths(.{
    .include = &.{ "engine-src/", "src/" },
    .exclude = &.{ "src/android/", "engine-src/generated.zig" },
});
```

would lint zig files under `engine-src/` and `src/` except for `engine-src/generated.zig` and any zig files under `src/android/`.

### Configure Rules

`addRule` accepts an anonymous struct representing the `Config` of rule being added. For example,

```zig
try builder.addRule(.{ .builtin = .field_naming }, .{
  .enum_field = .{ .style = .snake_case, .severity = .warning },
  .union_field = .off,
  .struct_field_that_is_type = .{ .style = .title_case, .severity = .@"error" },
  .struct_field_that_is_fn = .{ .style = .camel_case, .severity = .@"error" },
});
try builder.addRule(.{ .builtin = .no_deprecated }, .{
  .severity = .warning,
});
```

where `Config` struct are found in the rule source files [`no_deprecated.Config`](./src/rules/no_deprecated.zig) and [`field_naming.Config`](./src/rules/field_naming.zig).

### Disable with comments

#### `zlinter-disable-next-line [rule_1] [rule_n] [- comment]`

Disable all rules or an explicit set of rules for the next source code line. For example,

```zig
// zlinter-disable-next-line no_deprecated - not updating so safe
const a = this.is.deprecated();
```

#### `zlinter-disable-current-line [rule_1] [rule_n] [- comment]`

Disable all rules or an explicit set of rules for the current source code line. For example,

```zig
const a = this.is.deprecated(); // zlinter-disable-current-line
```

### Command line args

```shell
zig build lint -- [--include <path> ...] [--exclude <path> ...] [--filter <path> ...] [--rule <name> ...]
```

* `--include` run the linter on these path ignoring the includes and excludes defined in the `build.zig` forcing these paths to be resolved and linted (if they exist).
* `--exclude` exclude these paths from linting. This argument will be used in conjunction with the excludes defined in the `build.zig` unless used with `--include`.
* `--filter` used to filter the run to a specific set of already resolved paths. Unlike `--include` this leaves the includes and excludes defined in the `build.zig` as is.

For example

```shell
zig build lint -- --include src/ android/ --exclude src/generated.zig --rule no_deprecated no_unused
```

* Will resolve all zig files under `src/` and `android/` but will exclude linting `src/generated.zig`; and
* Only rules `no_deprecated` and `no_unused` will be ran.

## Rules

### Builtin rules

> [!NOTE]  
> :wrench: **[Experimental]** The wrench indicates that some problems reported by this rule can be automatically fixed with
> the `--fix` option. Please only use this option if you use source control. This
> is also subject to change. For now it simply uses text based patches but
> perhaps an AST or token based approach would be better. For now, it's best to
> see this as experimental, and to apply caution appropriately.

#### `no_deprecated`

* [Source code](./src/rules/no_deprecated.zig)

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

If you're indefinitely targetting fixed versions of a dependency or zig then using deprecated items may not be a big deal. Although, it's still worth undertsanding why they're deprecated, as there may be risks associated with use.

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

Alternatively, take a look at https://github.com/KurtWagner/zlinter-custom-rule-example, which is a minimal custom rule example with accompanying zig project.

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

### Run lint on self

```shell
zig build lint
```
