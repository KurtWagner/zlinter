const sub_module = @import("sub_module");

const Namespace = struct {
    pub const CallbackFn = *const fn () void;
    pub const TypeFactoryFn = *const fn () type;
    pub const SomeTypeAlias = type;
    pub const SomeType = struct {};
};

fn takesNamespaceCallback(bad_fn: Namespace.CallbackFn, goodCallback: Namespace.CallbackFn) void {
    _ = bad_fn;
    _ = goodCallback;
}

fn takesNamespaceTypeFactory(bad_factory: Namespace.TypeFactoryFn, GoodFactory: Namespace.TypeFactoryFn) void {
    _ = bad_factory;
    _ = GoodFactory;
}

fn takesNamespaceType(bad_type: Namespace.SomeTypeAlias, GoodType: Namespace.SomeTypeAlias) void {
    _ = bad_type;
    _ = GoodType;
}

fn takesNamespaceValue(good_value: Namespace.SomeType) void {
    _ = good_value;
}

fn takesImportedCallback(bad_imported_fn: sub_module.CallbackFn, importedCallback: sub_module.CallbackFn) void {
    _ = bad_imported_fn;
    _ = importedCallback;
}

fn takesImportedTypeFactory(bad_imported_factory: sub_module.TypeFactoryFn, ImportedFactory: sub_module.TypeFactoryFn) void {
    _ = bad_imported_factory;
    _ = ImportedFactory;
}

fn takesImportedType(bad_imported_type: sub_module.SomeTypeAlias, ImportedType: sub_module.SomeTypeAlias) void {
    _ = bad_imported_type;
    _ = ImportedType;
}

fn takesGeneric(T: type, value: T, BadValue: T) void {
    _ = value;
    _ = BadValue;
}
