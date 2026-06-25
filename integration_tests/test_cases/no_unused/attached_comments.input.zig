/// Removed with unused helper.
fn oldParser() void {}

// Parser helpers

fn separatedSection() void {}

/// Removed with multi-line helper.
fn oldParserWithArgs(
    input: []const u8,
) void {
    _ = input;
}

/// Removed with adjacent unused helper.
fn adjacentUnused() void {}

/// Kept with used helper.
fn helper() void {}

pub fn main() void {
    helper();
}
