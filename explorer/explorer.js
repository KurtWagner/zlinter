

const default_code = [
    "pub fn main() void {",
    "    std.debug.print(\"Hello AST explorer!\", .{});",
    "}",
    "const std = @import(\"std\");",
    "",
].join("\n");

const wasm_promise = fetch('wasm.wasm')
    .then(response => response.arrayBuffer())
    .then(file => WebAssembly.instantiate(file))
    .then(wasm => wasm.instance.exports)

function parse(source) {
    return wasm_promise
        .then(({ memory, parse }) => {
            const encoded_input = (new TextEncoder()).encode(source);
            const array_input = new Uint8Array(memory.buffer, 0, encoded_input.length);
            array_input.set(encoded_input, 0);

            const out_len = parse(array_input.byteOffset, encoded_input.length);
            const json_str = (new TextDecoder()).decode(new Uint8Array(memory.buffer, 0, out_len));
            return JSON.parse(json_str);
        });
}

(() => {
    const input_element = document.getElementById("input");
    const line_numbers_element = document.getElementById("line_numbers");
    const highlight_element = document.getElementById("highlight");
    const tree_element = document.getElementById("tree");

    var last_json = null;

    const getCursorPosition = () => {
        const selection = window.getSelection();
        if (selection.rangeCount) {
            const range = selection.getRangeAt(0);
            if (range.commonAncestorContainer.parentNode == input_element) {
                return range.endOffset;
            }
        }
        return 0;
    };

    const setCursorPosition = (pos) => {
        const selection = window.getSelection()

        const range = document.createRange()
        range.setStart(input_element.childNodes[0], pos)
        range.collapse(true)

        selection.removeAllRanges()
        selection.addRange(range)
    }


    input_element.addEventListener('input', syncLineNumbers);
    input_element.addEventListener('input', syncTree);
    input_element.addEventListener('keyup', syncCursorToken);
    input_element.addEventListener('click', syncCursorToken);

    input_element.textContent = default_code;
    input_element.dispatchEvent(new Event('input'));

    function syncLineNumbers() {
        const num_of_lines = input_element.textContent.split("\n").length;

        var fill = [];
        for (let i = 1; i <= num_of_lines; i++) fill.push(i);
        fill.push(num_of_lines + 1);

        line_numbers_element.innerHTML = fill.join("\n");
    }

    function syncCursorToken() {
        const highlight_class = "tree__node--highlighted";
        [...document.getElementsByClassName(highlight_class)].forEach(elem => elem.classList.remove(highlight_class));

        const token_tuple = getSelectedToken();
        if (token_tuple == null) return;
        console.log("Selected token", token_tuple[1]);


        var smallest_elem = null;
        [...document.getElementsByClassName("tree__node")].forEach(elem => {

            const first_token = elem.dataset.firstToken;
            const last_token = elem.dataset.lastToken;
            if (first_token == null || last_token == null) return;

            const [token_i,] = token_tuple;
            if (token_i >= first_token && token_i <= last_token) {
                smallest_elem = elem;
            }
        });

        if (smallest_elem) {
            smallest_elem.classList.add(highlight_class);
            smallest_elem.scrollIntoView();
        }




    }

    function getSelectedToken() {
        const pos = getCursorPosition();
        if (pos == 0) return null;
        if (!last_json) return null;

        for (let i = 0; i < last_json.tokens.length; i++) {
            const token = last_json.tokens[i];
            if (pos >= token.start && pos < token.start + token.len) {
                return [i, token];
            }
        }
        return null;
    }


    function syncTree() {

        parse(input_element.textContent)
            .then(json => {
                last_json = json;



                const pos = getCursorPosition();
                const raw = input_element.textContent;
                input_element.innerHTML = raw;
                setCursorPosition(pos);



                console.log('raw', raw);

                var prev = 0;
                const syntax = [];
                for (const token of json.tokens) {
                    syntax.push(raw.slice(prev, token.start));

                    const slice = raw.slice(token.start, token.start + token.len);
                    if (token.tag.startsWith('keyword_')) {
                        syntax.push(`<span class="syntax-keyword">${slice}</span>`);
                    } else if (token.tag.startsWith('string_literal')) {
                        syntax.push(`<span class="syntax-string-literal">${slice}</span>`);
                    } else if (['l_brace', 'r_brace'].includes(token.tag)) {
                        syntax.push(`<span class="syntax-brace">${slice}</span>`);
                    } else {
                        syntax.push(slice);
                    }

                    prev = token.start + token.len;
                }
                syntax.push(raw.slice(prev));

                console.log('syntax', syntax.join(""));

                highlight_element.innerHTML = syntax.join("");




                console.log(json);

                const tokens = json.tokens;

                tree_element.innerHTML = "";


                const tree_root_element = createTreeNode({
                    tag: "root",
                    body: json.body,
                });

                const maybe_errors = createTreeErrors(json);
                if (maybe_errors) tree_root_element.prepend(maybe_errors);

                tree_element.append(tree_root_element);


                function createTreeErrors(json_object) {
                    if (json_object.errors.len == 0) return;

                    const errors_element = document.createElement('div');
                    errors_element.classList.add("tree__node__errors");

                    for (const error of json_object.errors) {
                        const error_element = document.createElement("div");
                        error_element.classList.add("tree__node__errors__error");

                        for (const [key, val] of Object.entries(error)) {
                            const error_field_element = document.createElement("div");
                            error_field_element.classList.add("tree__node__errors__error__field");

                            const name_element = document.createElement('span');
                            name_element.classList.add('tree__node__errors__error__field__name');
                            name_element.textContent = key;
                            error_field_element.append(name_element);

                            const value_element = document.createElement('span');
                            value_element.classList.add('tree__node__errors__error__field__value');
                            value_element.textContent = val;
                            error_field_element.append(value_element);

                            error_element.append(error_field_element);
                        }
                        errors_element.append(error_element);
                    }

                    return errors_element;
                }


                function createTreeNode(json_object) {
                    const div = document.createElement('div');
                    div.classList.add('tree__node');

                    div.setAttribute("data-first-token", json_object.first_token);
                    div.setAttribute("data-last-token", json_object.last_token);

                    for (const [key, val] of Object.entries(json_object)) {
                        if (key == "body") continue;

                        const field_div = document.createElement('div');
                        field_div.classList.add('tree__node__field');

                        if (key == "tag") {
                            const tag_span = document.createElement('span');
                            tag_span.classList.add('tree__node__field__tag');
                            tag_span.textContent = val;
                            field_div.append(tag_span);
                        } else {

                            const name_span = document.createElement('span');
                            name_span.classList.add('tree__node__field__name');
                            name_span.textContent = key;
                            field_div.append(name_span);

                            const value_span = document.createElement('span');
                            value_span.classList.add('tree__node__field__value');
                            value_span.textContent = val;
                            field_div.append(value_span);

                            if (key.endsWith("_token")) {
                                const meta_span = document.createElement('span');
                                meta_span.classList.add('tree__node__field__meta');
                                meta_span.textContent = getTokenDescription(val);
                                field_div.append(meta_span);
                            }
                        }

                        div.append(field_div);
                    }

                    if (json_object.body && json_object.body.length > 0) {
                        const field_div = document.createElement('div');
                        field_div.classList.add('tree__node__field');

                        const name_span = document.createElement('span');
                        name_span.classList.add('tree__node__field__name');
                        name_span.textContent = "body";
                        field_div.append(name_span);

                        div.append(field_div);

                        for (const child_node of json_object.body) {
                            div.append(createTreeNode(child_node))
                        }
                    }


                    return div;


                }

                function getTokenDescription(token) {
                    const parts = [];
                    for (const [key, val] of Object.entries(json.tokens[token] || {})) {
                        parts.push(`${key}: ${val}`);
                    }
                    return parts.join(", ");
                }
            });
    }
})();



