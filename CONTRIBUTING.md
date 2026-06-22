# Contributing

Contributions and new rules or formatters are very welcome.

Rules are per project configurable, so there is usually room for new opinionated ones as long as they are not completely bespoke.

If you notice breaking changes in `zig` that will not be picked up by a `Deprecated:` comment then consider contributing to the `no_deprecated.zig` rule, with a specific check for the change. For example, `zig` removed `usingnamespace` in `0.15` so `no_deprecated.zig` will explicitly check and report the usage of `usingnamespace` keyword in `0.14` runs.

## Commit Messages

Keep commit messages short and scoped, and name the affected rule, feature, or subsystem.

```text
<type>(<scope>): <summary>
```

For example,

```text
fix(no_literal_args): unwrap parenthesized literal arguments
new(no_empty_block): add new empty block rule
test(no_todo): cover TODO comments with issue links
docs(no_globals): clarify allowed global state comments
refactor(rules): share literal expression helpers
```

These commit types should cover most cases:

- `fix(...)` for bug fixes or behavior changes in existing code.
- `new(...)` for new rules, config options, or user-facing features.
- `test(...)` for test-only changes.
- `docs(...)` for documentation-only changes.
- `refactor(...)` for internal restructuring without intended behavior changes.
- `perf(...)` for performance-focused changes.
- `chore(...)` for build, formatting, dependency, or repository maintenance.

For rule changes, use the rule id as the scope. For example,

```text
fix(no_empty_block): allow ABI-style empty function stubs
```

If a change affects multiple rules, use the main affected rule when that’s clear, otherwise use a broader scope. For example,

```text
refactor(rules): share AST block helpers
chore(integration): update lint expectations
```

Keep the summary concise and imperative. Add a body only when the rationale or tradeoff is not obvious from the subject.

## Dependencies

Zlinter avoids dependencies. It's just too much of a burden right now to depend on something written for Zig when Zig isn't 1.x.

The AST Explorer provided with Zlinter will be similar and aims to be minimal. Ideally no build system, no dependencies, just plain JS and CSS targetting modern browers as the target audience should all have access to such things.

## Run tests

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

To focus on a single rule when running integration tests:

```shell
zig build integration-test -Dtest_focus_on_rule=require_braces
```

## Run on self

```shell
zig build lint
```

## Regenerate documentation

```shell
zig build docs
```
