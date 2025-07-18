

const default_code = [
    "",
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

    input_element.addEventListener('input', syncLineNumbers);
    input_element.addEventListener('input', syncTree);

    input_element.textContent = default_code;
    input_element.dispatchEvent(new Event('input'));

    function syncLineNumbers() {
        const num_of_lines = input_element.textContent.split("\n").length;

        var fill = [];
        for (let i = 1; i <= num_of_lines; i++) fill.push(i);
        fill.push(num_of_lines + 1);

        line_numbers_element.innerHTML = fill.join("\n");
    }


    function syncTree() {

        parse(input_element.textContent)
            .then(json => {




                const raw = input_element.textContent;


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
                tree_element.append(createTreeNode({
                    tag: "root",
                    body: json.body,
                }));


                function createTreeNode(json_object) {
                    const div = document.createElement('div');
                    div.classList.add('tree__node');

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

