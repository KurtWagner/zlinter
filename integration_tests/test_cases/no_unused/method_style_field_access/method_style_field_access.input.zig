const Store = @This();

pub fn main(store: *Store) void {
    store.used();
}

fn used(self: *Store) void {
    _ = self;
}
