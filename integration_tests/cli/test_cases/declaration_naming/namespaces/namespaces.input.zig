const my_good_namespace = struct {
    const abc: u32 = 0;
};
const MyBadNamespace = my_good_namespace;
const myBadNamespace = my_good_namespace;
