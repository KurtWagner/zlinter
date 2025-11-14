# Check compiled source

Checks that resolving from a compiled unit works as intended with excludes.

The test simply:

1. Doesn't import `unused.zig` so the lint error from this should not be reported
2. Does import `excluded.zig` but it's then excluded in the build config so the lint error should not be reported.
3. Does import `used.zig` so should report the lint errors in it.

See also `zig build integration-check`.
