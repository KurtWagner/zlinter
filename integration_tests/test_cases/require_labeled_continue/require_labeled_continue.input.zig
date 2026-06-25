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

    while (true) {
        const SingleLoop = struct {
            fn f() void {
                while (true) {
                    continue;
                }
            }
        };
        _ = SingleLoop;
    }

    while (true) {
        const NestedLoop = struct {
            fn f() void {
                while (true) {
                    while (true) {
                        continue;
                    }
                }
            }
        };
        _ = NestedLoop;
    }
}
