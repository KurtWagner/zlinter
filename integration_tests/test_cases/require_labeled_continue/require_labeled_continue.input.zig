pub fn main() void {
    while (true) {
        while (true) {
            continue;
        }
    }

    outer: while (true) {
        while (true) {
            if (true) continue :outer;
        }
    }

    for (0..1) |_| {
        for (0..1) |_| {
            continue;
        }
    }
}
