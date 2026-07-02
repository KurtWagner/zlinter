# Release Notes

This document is best effort (possibly incomplete) list of signficant changes
in `zlinter` between its Zig version branches.

## master / 0.17.x (WIP)

These notes compare `master` against the `0.16.x` branch.

### Build integration

* `zlinter` no longer depends on ZLS. The library now builds around `std.zig`
  and `std.Build.Configuration`, with its own stores (interning).
* The `addRule` API no longer takes `b` for custom rules. In `0.16.x`, custom
  rule examples used:

  ```zig
  // Before:
  builder.addRule(b, .{
      .custom = .{
          .name = "no_cats",
          .path = "src/no_cats.zig",
      },
  }, .{});
  
  // Now:
  builder.addRule(.{
      .custom = .{
          .name = "no_cats",
          .path = "src/no_cats.zig",
      },
  }, .{});
  ```

* `addPaths` now distinguishes files from directories.

  ```zig
  // Before:
  builder.addPaths(.{
      .include = &.{ b.path("engine-src/"), b.path("src/") },
      .exclude = &.{ b.path("src/android/"), b.path("engine-src/generated.zig") },
  });
  
  // Now:
  builder.addPaths(.{
      .include_dirs = &.{ b.path("engine-src"), b.path("src") },
      .exclude_dirs = &.{ b.path("src/android") },
      .exclude_files = &.{ b.path("engine-src/generated.zig") },
  });
  ```

### Compiled units and import context

* Compiled unit handling is now explicit and separate from file path includes.
  Use `builder.setCompileUnits` to choose which build graph units supply module
  and import context while linting.
* If you do not call `setCompileUnits`, `zlinter` chooses a default set from
  discovered units, preferring executables, then libraries, then tests, then
  objects, then test objects.
* Available selectors are `.exe`, `.lib`, `.obj`, `.@"test"`, `.all`, and
  `.{ .explicit = compile_step }`.
* Use `.all` only when you intentionally want every discovered compile unit to
  provide context. It can be much slower on large build graphs.
* This replaces the older approach of adding a compiled unit as an include
  source. For example,

  ```zig
  const exe = b.addExecutable(.{
      .name = "my_app",
      .root_module = app_module,
  });

  var builder = zlinter.builder(b, .{});
  builder.setCompileUnits(&.{.{ .explicit = exe }});
  ```

### Rule configuration shape

* Several reusable config helper types are now tagged unions keyed by severity.
* `LintTextStyleWithSeverity`:

  ```zig
  // Before:
  .{ .style = .snake_case, .severity = .warning }
  

  // Now:
  .{ .warning = .snake_case }
  .{ .@"error" = .snake_case }
  ```

* `LintTextOrderWithSeverity`:

  ```zig
  // Before:
  .{ .order = .alphabetical_ascending, .severity = .warning }
  
  // Now:
  .{ .warning = .alphabetical_ascending }
  ```

* `LenAndSeverity`:

  ```zig
  // Before
  .{ .len = 3, .severity = .warning }
  
  // Now:
  .{ .warning = .{ .len = 3 } }
  ```

* `.off` remains the disabled value for these tagged-union config fields.

### Rule changes

* `no_undefined` was removed and replaced with `no_unsafe_undefined`.
  The replacement focuses on unsafe `undefined` situations such as returns,
  block breaks, optionals, pointers, enums/tagged unions, const declarations,
  and primitive scalars, while allowing common scratch-buffer and out-parameter patterns.

### Directory-level configuration

* `zlinter.zon` files are now supported for per-directory rule overrides.
  A `zlinter.zon` file applies to the directory it is in and descendants.
* Directory configs only override rules already enabled in `build.zig` they can
  **not** enable new rules on their own.
* The config structure is like:

  ```zig
  .{
      .rules = .{
          .field_naming = .{
              .enum_field = .off,
          },
      },
  }
  ```

### Custom rule API

* The rule run function signature changed. In `0.16.x` it received
  `*zlinter.session.LintContext`, `*const zlinter.session.LintDocument`, a
  general allocator, and run options. On `master` it receives
  `*zlinter.session.LintSession`, `*const zlinter.session.LintDocument`, and
  run options.
* Custom rules should get allocators from `session.runtime`, usually
  `session.runtime.sessionArena()` for returned diagnostics and
  `session.runtime.ruleArena()` for temporary rule work.
* `LintContext` is gone from the public session surface. The replacement public
  session types are exported under `zlinter.session`, including `LintSession`,
  `LintDocument`, `LintRuntime`, `FileStore`, `ModuleStore`, `DeclStore`,
  `TypeStore`, and `BuildConfigStore`.
* `LintDocument` no longer exposes the old direct handle fields used by many
  custom rules.

  ```zig
  // Before:
  const tree = doc.handle.tree;
  const path = doc.path;

  // Now:
  const tree = doc.tree(session);
  const path = doc.absPath(session);
  ```

* `LintResult.init` results should be allocated from the session arena and use
  `doc.absPath(session)`.
* The bundled `zlinter.testing` helpers changed to construct a `LintSession`
  rather than a `LintContext`. `testRunRule` now accepts `TestRunOptions`,
  including `.allow_parse_errors`.
* `zlinter.results.LintProblem` now supports optional notes, which built-in
  rules use to point at resolved declarations. THis allows findings to
  disambiguate between compiled unit module trees.

### Command line and diagnostics

* The command-line surface remains broadly the same:

  ```shell
  zig build lint -- [--include <path> ...] [--exclude <path> ...] [--filter <path> ...] [--rule <name> ...] [--fix] [--quiet] [--max-warnings <u32>]
  ```

* `--include`, `--exclude`, and `--filter` now run against the new file/module
  resolution model.
  * `--include` still overrides build-configured includes and excludes
  * `--filter` still filters already resolved paths.
