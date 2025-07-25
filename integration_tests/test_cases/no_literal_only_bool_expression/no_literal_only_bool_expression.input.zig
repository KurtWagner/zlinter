const age = 10;

pub fn main() void {
    const bad = 1 == 2;
    const also_bad = age == 10 and 1 == 1;
    const good = age > 10;

    _ = good;
    _ = bad;
    _ = also_bad;

    // Good:
    while (true) {
        break;
    }

    // Bad:
    while (false) {}
    while (1 == 1) {
        break;
    }

    // Good
    if (age < 10) {}
    if (age == 10) {}
    if (age == 10 or age < 50) {}

    // Bad
    if (1 == 2) {}
    if (2 >= 1) {}
    if (1 == 2 or (1 > 10 and age < 10)) {}
}
