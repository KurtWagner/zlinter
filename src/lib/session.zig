//! Linting module for items relating to the linting session (e.g., overall context
//! and document store).

pub const BuildConfigStore = @import("session/BuildConfigStore.zig");
pub const CompileContext = @import("session/CompileContext.zig");
pub const DeclStore = @import("session/DeclStore.zig");
pub const FileStore = @import("session/FileStore.zig");
pub const LintContext = @import("session/LintContext.zig");
pub const LintDocument = @import("session/LintDocument.zig");
pub const ModuleStore = @import("session/ModuleStore.zig");
pub const TypeStore = @import("session/TypeStore.zig");

pub const max_zig_file_size_bytes = common.max_zig_file_size_bytes;

const std = @import("std");
const common = @import("session/common.zig");

test {
    std.testing.refAllDecls(@This());
}
