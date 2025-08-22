pub const zig: enum {
    @"0.16",
    @"0.15",
    @"0.14",
} = version: {
    const major = builtin.zig_version.major;
    const minor = builtin.zig_version.minor;
    break :version if (major == 0 and minor == 16)
        .@"0.16"
    else if (major == 0 and minor == 15)
        .@"0.15"
    else if (major == 0 and minor == 14)
        .@"0.14"
    else
        @compileError("Zig version not supported: " ++ builtin.zig_version_string);
};

const builtin = @import("builtin");
