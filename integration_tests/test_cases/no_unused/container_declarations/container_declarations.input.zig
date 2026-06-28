pub const BadParser = struct {
    fn unusedHelper() void {}

    pub fn parse() void {}
};

pub const GoodParser = struct {
    fn helper() void {}

    pub fn parse() void {
        helper();
    }
};
