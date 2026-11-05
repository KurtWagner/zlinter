# Check compiled source

Checks that resolving from a compiled unit works as intended with excludes.

The test simply:

1. Doesn't import `unused.zig` so the lint error from this should not be reported
2. Does import `excluded.zig` but it's then excluded in the build config so the lint error should not be reported.
3. Imports `used.zig` through two levels of named modules and file imports, so should report the lint errors in it.
4. Handles multiple imports on a line, multiline imports, and escaped import paths, while ignoring imports inside comments and strings.

See also `zig build integration-check`.
