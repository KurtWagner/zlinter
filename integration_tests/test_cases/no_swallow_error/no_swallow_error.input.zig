pub fn main() void {
    // Ok:
    takeYourChances(1) catch |e| {
        std.log.err("Wrong guess: {s}", .{@errorName(e)});
    };

    if (takeYourChances(1)) {
        std.log.debug("Winner", .{});
    } else |e| {
        std.log.err("Wrong guess: {s}", .{@errorName(e)});
    }

    // Not ok:
    takeYourChances(0) catch {};
    takeYourChances(2) catch unreachable;
    takeYourChances(2) catch {
        unreachable;
    };
    if (takeYourChances(1)) {} else |_| {}
    if (takeYourChances(1)) {} else |_| unreachable;
    if (takeYourChances(1)) {} else |_| {
        unreachable;
    }
}

test {
    // Ok as in test which is excluded by default
    takeYourChances(0) catch {};
    takeYourChances(2) catch unreachable;
    takeYourChances(2) catch {
        unreachable;
    };
    if (takeYourChances(1)) {} else |_| {}
    if (takeYourChances(1)) {} else |_| unreachable;
    if (takeYourChances(1)) {} else |_| {
        unreachable;
    }
}

fn takeYourChances(guess: u32) error{WrongGuess}!void {
    if (guess != 1) return error.WrongGuess;
}

const std = @import("std");
