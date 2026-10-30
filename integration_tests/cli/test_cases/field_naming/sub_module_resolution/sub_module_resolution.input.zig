const sub_module = @import("sub_module");

const Example = struct {
    bad_callback: sub_module.CallbackFn,
    importedCallback: sub_module.CallbackFn,
    bad_factory: sub_module.TypeFactoryFn,
    ImportedFactory: sub_module.TypeFactoryFn,
    bad_type: sub_module.SomeTypeAlias,
    ImportedType: sub_module.SomeTypeAlias,
    good_value: sub_module.EnumType,
};
