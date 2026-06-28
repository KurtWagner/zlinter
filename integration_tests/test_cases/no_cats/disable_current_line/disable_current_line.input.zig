pub const some_cats = false; // zlinter-disable-current-line

pub const more_cats = false; // zlinter-disable-current-line no_cats

pub const even_more_cats = false; // zlinter-disable-current-line no_cats no_unused - a comment

// Expect to catch this:
pub const bad_cats = false; // zlinter-disable-current-line no_unused
