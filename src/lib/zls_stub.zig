//! Minimal local no-op stub for the ZLS
//!
//! Just to assist in the migration to the updated build system in 0.17.
//! Essentially want to try and migrate and update zlinter without needing
//! ZLS to also be updated...
//!
//! TODO: #149 remove stub and use real thing or our own type and desclarion resolver

const std = @import("std");

pub const Config = struct {
    zig_exe_path: ?[]const u8 = null,
    zig_lib_path: ?[]const u8 = null,
    build_runner_path: ?[]const u8 = null,
    builtin_path: ?[]const u8 = null,
};

pub const Uri = struct {
    raw: []const u8,

    pub fn fromPath(allocator: std.mem.Allocator, path: []const u8) !Uri {
        return .{ .raw = try allocator.dupe(u8, path) };
    }
};

pub const DocumentStore = struct {
    pub const Config = struct {
        zig_exe_path: ?[]const u8 = null,
        zig_lib_dir: ?OpenedDir = null,
        build_runner_path: ?[]const u8 = null,
        builtin_path: ?[]const u8 = null,
        wasi_preopens: void = {},
    };

    pub const OpenedDir = struct {
        handle: std.Io.Dir,
        path: []const u8,
    };

    pub const Handle = struct {
        uri: Uri,
        tree: std.zig.Ast,
        source: [:0]u8,
    };

    io: std.Io,
    allocator: std.mem.Allocator,
    config: DocumentStore.Config,
    handles: std.ArrayList(*Handle) = .empty,

    pub fn deinit(self: *DocumentStore) void {
        for (self.handles.items) |handle| {
            handle.tree.deinit(self.allocator);
            self.allocator.free(handle.source);
            self.allocator.free(handle.uri.raw);
            self.allocator.destroy(handle);
        }
        self.handles.deinit(self.allocator);

        if (self.config.zig_lib_dir) |dir| {
            var handle = dir.handle;
            handle.close(self.io);
        }
    }

    pub fn getOrLoadHandle(self: *DocumentStore, uri: Uri) !?*Handle {
        for (self.handles.items) |handle| {
            if (std.mem.eql(u8, handle.uri.raw, uri.raw)) return handle;
        }

        const source = try std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            uri.raw,
            self.allocator,
            .limited(std.math.maxInt(u32)),
            .@"1",
            0,
        );
        errdefer self.allocator.free(source);

        var tree = try std.zig.Ast.parse(self.allocator, source, .zig);
        errdefer tree.deinit(self.allocator);

        const handle = try self.allocator.create(Handle);
        errdefer self.allocator.destroy(handle);

        handle.* = .{
            .uri = .{ .raw = try self.allocator.dupe(u8, uri.raw) },
            .tree = tree,
            .source = source,
        };
        errdefer self.allocator.free(handle.uri.raw);

        try self.handles.append(self.allocator, handle);
        return handle;
    }
};

pub const Analyser = struct {
    pub const DeclWithHandle = struct {
        decl: Decl,
        handle: *DocumentStore.Handle,

        pub fn docComments(_: DeclWithHandle, _: std.mem.Allocator) !?[]const u8 {
            return null;
        }

        pub fn definitionToken(
            self: DeclWithHandle,
            _: *Analyser,
            _: bool,
        ) error{ OutOfMemory, Canceled }!TokenWithHandle {
            return .{
                .token = switch (self.decl) {
                    .ast_node => |node| self.handle.tree.nodeMainToken(node),
                    .error_token => |token| token,
                    .other => 0,
                },
                .handle = self.handle,
            };
        }
    };

    pub const TokenWithHandle = struct {
        token: std.zig.Ast.TokenIndex,
        handle: *DocumentStore.Handle,
    };

    pub const NodeWithHandle = struct {
        node: std.zig.Ast.Node.Index,
        handle: *DocumentStore.Handle,

        pub fn of(node: std.zig.Ast.Node.Index, handle: *DocumentStore.Handle) NodeWithHandle {
            return .{
                .node = node,
                .handle = handle,
            };
        }
    };

    pub const DeclWithHandleAndType = struct {
        @"0": DeclWithHandle,
        @"1": Type,
    };

    pub const Decl = union(enum) {
        ast_node: std.zig.Ast.Node.Index,
        error_token: std.zig.Ast.TokenIndex,
        other,
    };

    pub const Type = struct {
        pub const Data = union(enum) {
            ip_index: IpIndex,
            container: Container,
            unknown,
        };

        pub const IpIndex = struct {
            type: enum { unknown_type, unknown_unknown, other } = .unknown_unknown,
            index: ?usize = null,
        };

        pub const Container = struct {
            scope_handle: ScopeHandle,
        };

        pub const ScopeHandle = struct {
            handle: *DocumentStore.Handle,
            node: std.zig.Ast.Node.Index = .root,

            pub fn toNode(self: ScopeHandle) std.zig.Ast.Node.Index {
                return self.node;
            }
        };

        is_type_val: bool = false,
        data: Data = .{ .ip_index = .{} },

        pub fn eql(self: Type, other: Type) bool {
            return self.is_type_val == other.is_type_val and std.meta.activeTag(self.data) == std.meta.activeTag(other.data);
        }

        pub fn resolveDeclLiteralResultType(self: Type) Type {
            return self;
        }

        pub fn instanceTypeVal(self: Type, analyser_arg: anytype) InstanceTypeValReturn(@TypeOf(analyser_arg)) {
            return if (self.is_type_val) self else null;
        }

        fn InstanceTypeValReturn(comptime AnalyserArg: type) type {
            return if (@typeInfo(AnalyserArg) == .pointer) error{ OutOfMemory, Canceled }!?Type else ?Type;
        }

        pub fn isContainerType(self: Type) bool {
            return self.data == .container;
        }

        pub fn isEnumLiteral(_: Type) bool {
            return false;
        }

        pub fn isEnumType(_: Type) bool {
            return false;
        }

        pub fn isErrorSetType(_: Type, _: anytype) bool {
            return false;
        }

        pub fn isFunc(_: Type) bool {
            return false;
        }

        pub fn isGenericFunc(_: Type) bool {
            return false;
        }

        pub fn isMetaType(_: Type) bool {
            return false;
        }

        pub fn isNamespace(_: Type) bool {
            return false;
        }

        pub fn isOpaqueType(_: Type) bool {
            return false;
        }

        pub fn isStructType(_: Type, _: anytype) bool {
            return false;
        }

        pub fn isTaggedUnion(_: Type) bool {
            return false;
        }

        pub fn isTypeFunc(_: Type) bool {
            return false;
        }

        pub fn isUnionType(_: Type) bool {
            return false;
        }
    };

    pub fn init(
        _: std.mem.Allocator,
        _: std.mem.Allocator,
        _: *DocumentStore,
        _: ?*anyopaque,
    ) Analyser {
        return .{};
    }

    pub fn deinit(_: *Analyser) void {}

    pub fn resolveTypeOfNode(_: *Analyser, _: NodeWithHandle) error{ OutOfMemory, Canceled }!?Type {
        return null;
    }

    pub fn resolveVarDeclAlias(_: *Analyser, _: anytype) !?DeclWithHandle {
        return null;
    }

    pub fn lookupSymbolGlobal(
        _: *Analyser,
        _: *DocumentStore.Handle,
        _: []const u8,
        _: usize,
    ) !?DeclWithHandle {
        return null;
    }

    pub fn getSymbolFieldAccesses(
        _: *Analyser,
        _: std.mem.Allocator,
        _: *DocumentStore.Handle,
        _: usize,
        _: std.zig.Token.Loc,
        _: []const u8,
    ) !?[]const DeclWithHandle {
        return null;
    }

    pub fn lookupSymbolFieldInit(
        _: *Analyser,
        _: *DocumentStore.Handle,
        _: []const u8,
        _: std.zig.Ast.Node.Index,
        _: []const std.zig.Ast.Node.Index,
    ) !?DeclWithHandleAndType {
        return null;
    }
};
