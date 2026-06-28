const apple = @import("apple");
const banana = @import("banana");

const cat = @import("cat");
// import_order checks per scope, so although this chunk has the wrong order
// it won't be detected until the issues in the above chunk are fixed first.
const zebra = @import("zebra");

pub fn main() void {
    const apple_main = @import("apple_main");
    const banana_main = @import("apple_main");

    _ = banana_main;
    _ = apple_main;
}
