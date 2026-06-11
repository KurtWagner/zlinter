//! One configured compilation entry point whose root module gives meaning to
//! source files and imports. e.g., `addLibrary` and `addExecutable`.

name: []const u8,
kind: std.Build.Configuration.Step.Compile.Kind,
root_module: ModuleId,
target: Target,

pub const Id = enum(u32) {
    _,

    pub fn fromIndex(index: usize) Id {
        return @enumFromInt(@as(u32, @intCast(index)));
    }

    pub fn toIndex(self: Id) usize {
        return @intFromEnum(self);
    }
};

pub const Target = struct {
    cpu_arch: std.Target.Cpu.Arch,
    os_tag: std.Target.Os.Tag,
    abi: std.Target.Abi,
};

const std = @import("std");
const ModuleId = @import("./ModuleStore.zig").ModuleId;
