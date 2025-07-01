pub inline fn anytypeSample(in: anytype) type {
    const InType = @TypeOf(in);
    return InType;
}
