# Contributing

Contributions and new rules or formatters are very welcome.

Rules are per project configurable, so there is usually room for new opinionated ones as long as they are not completely bespoke.

If you notice breaking changes in `zig` that will not be picked up by a `Deprecated:` comment then consider contributing to the `no_deprecated.zig` rule, with a specific check for the change. For example, `zig` removed `usingnamespace` in `0.15` so `no_deprecated.zig` will explicitly check and report the usage of `usingnamespace` keyword in `0.14` runs.

## Commit Messages

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

There's a caching issue I havent resolved yet so you may need to clear cache
before building docs if its not updating as you expect.

## Build and serve website (with AST explorer)

```shell
zig build website && npx http-server -c-1 zig-out/website
```

You don't need to use `npx`, its just static content in `zig-out/website`. You may decide to use `python -m http.server` instead.
