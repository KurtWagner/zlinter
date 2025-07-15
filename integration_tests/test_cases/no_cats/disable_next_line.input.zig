// zlinter-disable-next-line
pub const some_cats = false;

// zlinter-disable-next-line no_cats
pub const more_cats = false;

// zlinter-disable-next-line no_cats no_unused - a comment
pub const even_more_cats = false;

// zlinter-disable-next-line no_unused
pub const bad_cats = false; // expect to catch this
