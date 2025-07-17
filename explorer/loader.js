
(async () => {
    const response = await fetch('wasm.wasm');
    const file = await response.arrayBuffer();
    const wasm = await WebAssembly.instantiate(file);

    const { memory, parse } = wasm.instance.exports;

    const source = (new TextEncoder()).encode("const a = @import(\"a\");");
    const in_array = new Uint8Array(memory.buffer, 0, source.length);
    in_array.set(source);

    const len = parse(in_array.byteOffset, in_array.length);

    const str = (new TextDecoder()).decode(new Uint8Array(memory.buffer, in_array.byteOffset + source.length, len));
    console.log(JSON.parse(str));
})();
