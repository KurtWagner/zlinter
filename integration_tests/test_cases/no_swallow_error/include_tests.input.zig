test {
    takeYourChances(0) catch {};
    if (takeYourChances(1)) {} else |_| unreachable;
}

fn takeYourChances(guess: u32) error{WrongGuess}!void {
    if (guess != 1) return error.WrongGuess;
}
