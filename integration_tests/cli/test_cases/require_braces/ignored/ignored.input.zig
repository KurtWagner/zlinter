// Situations that are normally errors but under certain situations are ignored.
pub fn ignored() void {
    const x = 10;

    const label = if (x > 10) "over 10" else "under 10";
    _ = label;

    return if (x > 20)
        "over 20"
    else
        "under 20";
}
