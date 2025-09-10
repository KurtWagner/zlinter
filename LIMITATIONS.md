# Limitations

> This is a work in progress document of limitations.

`zlinter` currently analyzes the Zig AST, which has [limited context](https://github.com/KurtWagner/zlinter/issues/65) without trying to re-implement the Zig compiler (not doing).

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
