# Integration tests

Contains a separate project that consumes zlinter as a dependency. Unit tests
should live in the parent source directory as `test` declarations.

The CLI suite lives in `cli/`, including its runner, test cases, custom rule,
and module resolution fixtures. The build files and fixture dependencies in
`deps/` are shared at the integration project root.

From the repository root, run all integration tests with:

```shell
zig build integration-test
```

To run only the CLI suite:

```shell
zig build cli-integration-test
```

From this directory, use `zig build test` for all integration tests or
`zig build cli-test` for the CLI suite. Add
`-Dtest_focus_on_rule=<rule_name>` to focus on one rule, or `--watch` to watch
the suite's inputs directly.
