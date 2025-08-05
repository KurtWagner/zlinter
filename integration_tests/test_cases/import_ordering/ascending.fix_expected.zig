const apple = @import("apple");
const appricot = @import("appricot");
const banana = @import("banana");

// import_order checks per scope, so although this chunk has the wrong order
// it won't be detected until the issues in the above chunk are fixed first.
const cat = @import("cat");
const zebra = @import("zebra");

pub fn main() void {
    const apple_main = @import("apple_main");
    const banana_main = @import("apple_main");

    _ = banana_main;
    _ = apple_main;
}

pub const namespace = struct {
    const apple_namespace = @import("apple_namespace");
    const banana_namespace = @import("apple_namespace");
};
