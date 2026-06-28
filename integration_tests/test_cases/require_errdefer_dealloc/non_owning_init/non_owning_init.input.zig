const ChildIterator = struct {
    fn init(tree: usize, node: usize) ChildIterator {
        _ = tree;
        _ = node;
        return .{};
    }
};

fn parse() !void {
    var it = ChildIterator.init(1, 2);
    _ = &it;
}
