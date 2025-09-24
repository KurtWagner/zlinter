# Limitations

> This is a work in progress document of limitations.

`zlinter` currently analyzes the Zig AST, which has limited context without trying to re-implement the Zig compiler (not doing).

A more accurate approach could be to integrate more closely with the Zig build system and compiler (e.g., the proposed Zig compiler server), but for now, using the AST should be sufficient for most cases, and maybe one day `zlinter` can use newer Zig Compiler APIs as they become available.

## Exclude test only code

Any rule that offers an option to exclude from tests is limited in what it can
exclude without relying on some sort of multi build process to truly see what
is included and excluded in test builds.

The current AST based heuristics should be effective for majority of cases but not all:

1. If included in `test {}` blocks, then it's a test
2. If included in an if statement containing a single condition (`*.is_test`), then it's a test

It will not detect:

1. More complex conditionals (e.g., `if (something or builtin.is_test)`)
2. If a piece of code is only ever included in tests

## Exclude debug only code

Similar to [test only code](#exclude-test-only-code), we can't reliably detect based on `builtin.mode` is debug.

## Unused code

Detecting unused code is limited in that it can't inform you whether it's truly unused in all builds except tests, which will give false negatives if your project is well tested, i.e., always referenced by some test.

Potentially this could be improved by ignoring references in `test { ... }` blocks but it wouldn't be bullet proof.

## No unnecessary branches

A potential `no_unnecessary_branches` rule has a similar issue to `no_unused` in that without analysing all test and non-test build variants you can't be certain something is truly dead.
