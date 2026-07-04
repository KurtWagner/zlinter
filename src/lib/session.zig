//! Linting module for items relating to the linting session (e.g., overall context
//! and document store).

pub const BuildConfigStore = @import("session/BuildConfigStore.zig");
pub const CompileContext = @import("session/CompileContext.zig");
pub const DeclStore = @import("session/DeclStore.zig");
pub const FileStore = @import("session/FileStore.zig");
pub const imports = @import("session/imports.zig");
pub const LintDocument = @import("session/LintDocument.zig");
pub const LintRuntime = @import("session/LintRuntime.zig");
pub const LintSession = @import("session/LintSession.zig");
pub const ModuleStore = @import("session/ModuleStore.zig");
pub const TypeStore = @import("session/TypeStore.zig");

pub const max_zig_file_size_bytes = common.max_zig_file_size_bytes;

const common = @import("session/common.zig");
const std = @import("std");

test {
    std.testing.refAllDecls(@This());
}
