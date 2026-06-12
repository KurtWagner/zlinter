//! One configured compilation entry point whose root module gives meaning to
//! source files and imports. e.g., `addLibrary` and `addExecutable`.
const CompileContext = @This();

root_module: ModuleId,
step_index: std.Build.Configuration.Step.Index,

pub const Id = enum(u32) {
    _,

    pub fn fromIndex(index: usize) Id {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: Id) usize {
        return @intFromEnum(self);
    }
};

pub fn kind(self: CompileContext, config: *const std.Build.Configuration) std.Build.Configuration.Step.Compile.Kind {
    const step = config.steps[self.step_index];
    const compile = step.extended.cast(
        config,
        std.Build.Configuration.Step.Compile,
    ).?;
    return compile.flags3.kind;
}

pub fn name(self: CompileContext, config: *const std.Build.Configuration) []const u8 {
    return config.steps[self.step_index].name.slice(config);
}

const std = @import("std");
const ModuleId = @import("./ModuleStore.zig").ModuleId;
