const sub_module = @import("sub_module");

const bad_name_for_enum_type = sub_module.EnumType;
const badNameForEnumType = sub_module.EnumType;
const GoodNameForEnumType = sub_module.EnumType;

const good_name_for_int_value = sub_module.int_value;
const badNameForIntValue = sub_module.int_value;
const BadNameForIntValue = sub_module.int_value;

const person_underscore = sub_module.getPerson(10);
const personCamelCase = sub_module.getPerson(10);
const PersonTitleCase = sub_module.getPerson(10);
