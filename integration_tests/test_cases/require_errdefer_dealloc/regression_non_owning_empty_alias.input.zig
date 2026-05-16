const JsonContext = struct {
    pub const empty: JsonContext = .{};
};

fn parse() !void {
    var root_json_object = JsonContext.empty;
    _ = &root_json_object;
}
