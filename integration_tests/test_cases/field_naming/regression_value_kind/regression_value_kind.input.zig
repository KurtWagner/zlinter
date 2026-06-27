const Ast = @import("std").zig.Ast;

const Token = enum {
    alpha,
    beta,
};

const namespace = struct {
    const value = 1;
};

const Example = struct {
    first: Token,
    last: ?Token,
    namespace_value: namespace,
    decl_name_token: Ast.TokenIndex,
    problem: ?struct {
        first: Ast.TokenIndex,
        last: Ast.TokenIndex,
    },
};
