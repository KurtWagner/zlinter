const NodeLineage = struct {};

const Example = struct {
    lineage: *const NodeLineage,
    lineageBad: *const NodeLineage,
    TypeField: type,
    bad_type_field: type,
};
