

const wasm_promise = fetch('wasm.wasm')
    .then(response => response.arrayBuffer())
    .then(file => WebAssembly.instantiate(file));

function parse(source) {
    return wasm_promise
        .then(wasm => wasm.instance.exports)
        .then(({ memory, parse }) => {
            const encoded_input = (new TextEncoder()).encode(source);
            const array_input = new Uint8Array(memory.buffer, 0, encoded_input.length);
            array_input.set(encoded_input);

            const out_len = parse(array_input.byteOffset, array_input.length);
            const json_str = (new TextDecoder()).decode(new Uint8Array(memory.buffer, array_input.byteOffset + encoded_input.length, out_len));
            return JSON.parse(json_str);
        });
}


(() => {
    const input_element = document.getElementById("input");
    const line_numbers_element = document.getElementById("line_numbers");


    input_element.addEventListener('input', syncLineNumbers);
    input_element.addEventListener('input', syncTree);

    input_element.innerText = [
        "",
        "pub fn main() void {",
        "    std.debug.print(\"Hello AST explorer!\", .{});",
        "}",
        "const std = @import(\"std\");",
        "",
    ].join("\n");
    input_element.dispatchEvent(new Event('input'));



    function syncLineNumbers() {
        var fill = [];
        const num_of_lines = input_element.innerText.split("\n").length;
        for (let i = 1; i <= num_of_lines; i++) {
            fill.push(i);
        }
        fill.push(num_of_lines + 1);
        line_numbers_element.innerHTML = fill.join("\n");
    }

    function syncTree() {
        parse(input_element.innerText).then(console.log);
    }
})();


