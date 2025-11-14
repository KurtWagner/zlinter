pub const dogs = @embedFile("./rubbish.txt");

pub fn hasPanic() void {
    @panic("whoops");
}
