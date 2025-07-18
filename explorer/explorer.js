(() => {
    const default_code = [
        "pub fn main() void {",
        "    std.debug.print(\"Hello AST explorer!\", .{});",
        "}",
        "const std = @import(\"std\");",
        "",
    ].join("\n");

    const wasmPromise = fetch('wasm.wasm')
        .then(response => response.arrayBuffer())
        .then(file => WebAssembly.instantiate(file))
        .then(wasm => wasm.instance.exports)

    function parse(source) {
        return wasmPromise
            .then(({ memory, parse }) => {
                const encodedInput = (new TextEncoder()).encode(source);
                const arrayInput = new Uint8Array(memory.buffer, 0, encodedInput.length);
                arrayInput.set(encodedInput, 0);

                const outLen = parse(arrayInput.byteOffset, encodedInput.length);
                const jsonStr = (new TextDecoder()).decode(new Uint8Array(memory.buffer, 0, outLen));
                return JSON.parse(jsonStr);
            });
    }

    const inputElem = document.getElementById("input");
    const lineNumbersElem = document.getElementById("line_numbers");
    const highlightElem = document.getElementById("highlight");
    const treeElem = document.getElementById("tree");

    var lastJson = null;

    const getCursorPosition = () => {
        const selection = window.getSelection();
        if (selection.rangeCount) {
            const range = selection.getRangeAt(0);
            if (range.commonAncestorContainer.parentNode == inputElem) {
                return range.endOffset;
            }
        }
        return 0;
    };

    const setCursorPosition = (pos) => {
        const range = document.createRange()
        range.setStart(inputElem.childNodes[0], pos)
        range.collapse(true)

        const selection = window.getSelection()
        selection.removeAllRanges()
        selection.addRange(range)
    }

    inputElem.addEventListener('input', syncLineNumbers);
    inputElem.addEventListener('input', syncTree);
    inputElem.addEventListener('keyup', syncCursorToken);
    inputElem.addEventListener('click', syncCursorToken);

    inputElem.textContent = default_code;
    inputElem.dispatchEvent(new Event('input'));

    function syncLineNumbers() {
        const noOfLines = inputElem.textContent.split("\n").length;

        var fill = [];
        for (let i = 1; i <= noOfLines; i++) fill.push(i);
        fill.push(noOfLines + 1);

        lineNumbersElem.innerHTML = fill.join("\n");
    }

    function syncCursorToken() {
        const highlightClass = "tree__node--highlighted";
        [...document.getElementsByClassName(highlightClass)].forEach(elem => elem.classList.remove(highlightClass));

        const tokenIndexAndToken = getSelectedToken();
        if (tokenIndexAndToken == null) return;

        var lowestOverlappingNode = null;
        [...document.getElementsByClassName("tree__node")].forEach(elem => {
            const { firstToken, lastToken } = elem.dataset;
            if (firstToken == null || lastToken == null) return;

            const [token_i,] = tokenIndexAndToken;
            if (token_i >= firstToken && token_i <= lastToken) {
                lowestOverlappingNode = elem;
            }
        });

        if (lowestOverlappingNode) {
            lowestOverlappingNode.classList.add(highlightClass);
            lowestOverlappingNode.scrollIntoView();
        }
    }

    function getSelectedToken() {
        const pos = getCursorPosition();
        if (pos == 0) return null;
        if (!lastJson) return null;

        for (let i = 0; i < lastJson.tokens.length; i++) {
            const token = lastJson.tokens[i];
            if (pos >= token.start && pos < token.start + token.len) {
                return [i, token];
            }
        }
        return null;
    }

    function syncTree() {
        parse(inputElem.textContent)
            .then(json => {
                console.debug('AST:', json);
                lastJson = json;

                const tokensWithError = new Set();
                for (const error of json.errors || []) {
                    tokensWithError.add(error.token);
                }

                const pos = getCursorPosition();
                const raw = inputElem.textContent;
                inputElem.innerHTML = raw;
                setCursorPosition(pos);

                var prev = 0;
                const syntax = [];
                for (let tokenIndex = 0; tokenIndex < json.tokens.length; tokenIndex++) {
                    const token = json.tokens[tokenIndex];

                    syntax.push(raw.slice(prev, token.start));

                    const classes = [];
                    if (tokensWithError.has(tokenIndex)) {
                        classes.push("syntax-error");
                    }

                    if (token.tag.startsWith('keyword_')) {
                        classes.push("syntax-keyword");
                    } else if (token.tag.startsWith('string_literal')) {
                        classes.push("syntax-string-literal");
                    } else if (['l_brace', 'r_brace'].includes(token.tag)) {
                        classes.push("syntax-brace");
                    }

                    const slice = raw.slice(token.start, token.start + token.len);
                    if (classes.length == 0) {
                        syntax.push(slice);
                    } else {
                        syntax.push(`<span class="${classes.join(' ')}">${slice}</span>`);
                    }

                    prev = token.start + token.len;
                }
                syntax.push(raw.slice(prev));
                highlightElem.innerHTML = syntax.join("");


                const treeRootElem = createTreeNode({
                    tag: "root",
                    body: json.body,
                });

                const maybeErrors = createTreeErrors(json);
                if (maybeErrors) treeRootElem.prepend(maybeErrors);

                treeElem.innerHTML = "";
                treeElem.append(treeRootElem);

                function createTreeErrors(jsonObj) {
                    if (jsonObj.errors.len == 0) return;

                    const errorsDiv = document.createElement('div');
                    errorsDiv.classList.add("tree__node__errors");

                    for (const error of jsonObj.errors) {
                        const errorDiv = document.createElement("div");
                        errorDiv.classList.add("tree__node__errors__error");

                        for (const [key, val] of Object.entries(error)) {
                            const errorFieldDiv = document.createElement("div");
                            errorFieldDiv.classList.add("tree__node__errors__error__field");

                            const nameSpan = document.createElement('span');
                            nameSpan.classList.add('tree__node__errors__error__field__name');
                            nameSpan.textContent = key;
                            errorFieldDiv.append(nameSpan);

                            const valueSpan = document.createElement('span');
                            valueSpan.classList.add('tree__node__errors__error__field__value');
                            valueSpan.textContent = val;
                            errorFieldDiv.append(valueSpan);

                            errorDiv.append(errorFieldDiv);
                        }
                        errorsDiv.append(errorDiv);
                    }
                    return errorsDiv;
                }


                function createTreeNode(jsonObj) {
                    const div = document.createElement('div');
                    div.classList.add('tree__node');

                    div.dataset.firstToken = jsonObj.first_token;
                    div.dataset.lastToken = jsonObj.last_token;

                    for (const [key, val] of Object.entries(jsonObj)) {
                        if (key == "body") continue;

                        const fieldDiv = document.createElement('div');
                        fieldDiv.classList.add('tree__node__field');

                        if (key == "tag") {
                            const tagSpan = document.createElement('span');
                            tagSpan.classList.add('tree__node__field__tag');
                            tagSpan.textContent = val;
                            fieldDiv.append(tagSpan);
                        } else {
                            const nameSpan = document.createElement('span');
                            nameSpan.classList.add('tree__node__field__name');
                            nameSpan.textContent = key;
                            fieldDiv.append(nameSpan);

                            const valueSpan = document.createElement('span');
                            valueSpan.classList.add('tree__node__field__value');
                            valueSpan.textContent = val;
                            fieldDiv.append(valueSpan);

                            if (key.endsWith("_token")) {
                                const meta_span = document.createElement('span');
                                meta_span.classList.add('tree__node__field__meta');
                                meta_span.textContent = getTokenDescription(val);
                                fieldDiv.append(meta_span);
                            }
                        }
                        div.append(fieldDiv);
                    }

                    if (jsonObj.body && jsonObj.body.length > 0) {
                        const fieldDiv = document.createElement('div');
                        fieldDiv.classList.add('tree__node__field');

                        const nameSpan = document.createElement('span');
                        nameSpan.classList.add('tree__node__field__name');
                        nameSpan.textContent = "body";
                        fieldDiv.append(nameSpan);

                        div.append(fieldDiv);

                        for (const child of jsonObj.body) {
                            div.append(createTreeNode(child))
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
