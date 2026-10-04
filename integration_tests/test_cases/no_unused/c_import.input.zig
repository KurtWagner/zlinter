const c = @cImport({
    @cDefine("LINTER_TEST_VALUE", "1");
});

pub fn main() void {
    _ = c.LINTER_TEST_VALUE;
}
