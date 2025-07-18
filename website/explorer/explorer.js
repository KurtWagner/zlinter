

// We use a hidden character WORD JOINER at the end of contenteditable content
// to ensure trailing newlines are actually rendered.
const trailing_character = "\u2060";

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
    const fmtButton = document.getElementById("fmt-button");

    var lastJson = null;

    const insideOfInput = (selection) => {
        return selection.focusNode &&
            insideOf(selection.focusNode, inputElem);

        function insideOf(node, parentNode) {
            return parentNode === node
                || parentNode.contains(node);
        };
    }

    const getCursorPosition = () => {
        const selection = document.getSelection();
        if (!insideOfInput(selection)) return 0; // Should this error?

        var offset = selection.focusOffset;
        var node = selection.focusNode;

        while (node !== inputElem) {
            if (interpretAsNewline(node)) {
                offset += 1; // For newline
            }

            if (node.previousSibling) {
                node = node.previousSibling;
                offset += normalizeNodeText(node).length;
            } else {
                node = node.parentNode;

            }
        }
        return offset;



    };

    const setCursorPosition = (pos) => {
        if (!inputElem.childNodes || inputElem.childNodes.length == 0) {
            console.error("Failed to set cursor position");
            return;
        }

        const range = document.createRange()
        range.setStart(inputElem.childNodes[0], pos)
        range.collapse(true)

        const selection = document.getSelection()
        selection.removeAllRanges()
        selection.addRange(range)
    }

    document.addEventListener('selectionchange', overrideCursorPosition);
    inputElem.addEventListener('keypress', overrideEnterKeyPress);
    inputElem.addEventListener('input', syncLineNumbers);
    inputElem.addEventListener('input', syncTree);
    inputElem.addEventListener('keyup', syncCursorToken);
    inputElem.addEventListener('click', syncCursorToken);
    fmtButton.addEventListener('click', triggerFmtButton);

    inputElem.textContent = default_code + trailing_character;
    inputElem.dispatchEvent(new Event('input'));

    function triggerFmtButton() {
        if (!lastJson) return;
        if (lastJson.render) {
            const new_content = lastJson.render + trailing_character;
            if (inputElem.textContent !== new_content) {
                inputElem.textContent = new_content;
                inputElem.dispatchEvent(new Event('input'));
            }
        }
    }

    // We want to force that the cursor is never individually on the last
    // character, which is our special trailing character.
    function overrideCursorPosition() {
        const selection = document.getSelection();
        if (selection.anchorOffset !== selection.focusOffset) return;
        if (!insideOfInput(selection)) return;

        if (inputElem.innerHTML.length == getCursorPosition()) {
            setCursorPosition(inputElem.innerHTML.length - 1);
        }
    }

    function overrideEnterKeyPress(e) {
        // None of the popular browsers seem to agree what new lines look like
        // in contenteditable elements. Firefox even seems to add two through
        // nested the current line in a div while adding a new one below. So
        // unfortunately we're going to get a little dirty and disable enter
        // and do it ourselves and pray for the best.
        if (e.key === 'Enter') {
            e.preventDefault();
            document.execCommand('insertLineBreak')
        }
    }

    function syncLineNumbers() {
        const noOfLines = normalizeNodeText(inputElem).split("\n").length;
        var fill = [];
        for (let i = 1; i <= noOfLines; i++) fill.push(i);

        lineNumbersElem.innerHTML = fill.join("\n");
    }

    function syncCursorToken() {
        const highlightClass = "tree__node--highlighted";
        [...document.getElementsByClassName(highlightClass)].forEach(elem => elem.classList.remove(highlightClass));

        const tokenIndexAndToken = getSelectedToken();
        if (tokenIndexAndToken === null) return;

        var lowestOverlappingNode = null;
        [...document.getElementsByClassName("tree__node")].forEach(elem => {
            const { firstToken, lastToken } = elem.dataset;
            if (firstToken === null || lastToken === null) return;

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

    function syncTree(e) {
        const pos = getCursorPosition();
        const textContent = normalizeNodeText(inputElem);
        inputElem.innerHTML = textContent + trailing_character;
        setCursorPosition(pos);

        parse(textContent)
            .then(json => {
                console.debug('AST:', json);
                lastJson = json;

                const tokensWithError = new Set();
                for (const error of json.errors || []) {
                    tokensWithError.add(error.token);
                }

                var prev = 0;
                const syntax = [];
                for (let tokenIndex = 0; tokenIndex < json.tokens.length; tokenIndex++) {
                    const token = json.tokens[tokenIndex];

                    syntax.push(textContent.slice(prev, token.start));

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

                    const slice = textContent.slice(token.start, token.start + token.len);
                    syntax.push(`<span data-token-index="${tokenIndex}" class="${classes.join(' ')}">${slice}</span>`);

                    prev = token.start + token.len;
                }
                syntax.push(textContent.slice(prev));
                highlightElem.innerHTML = syntax.join("") + trailing_character;

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
                        errorDiv.textContent = "AST Error"

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

// None of the popular browsers seem to agree what new lines look like
// in contenteditable elements. Firefox even seems to add two through
// nested the current line in a div while adding a new one below. So
// this method tries to help a little bit by implementing our own html to text
// logic instead of relying on reading innerText or textContent.
function normalizeNodeText(node) {
    return (() => {
        if (!node.childNodes || node.childNodes.length == 0) {
            return node.textContent;
        }

        // Empty in some browsers seem to just be a <br> child, which is unfortunate
        // as it can also mean a newline.
        if (node.childNodes.length == 1 && node.childNodes[0].nodeName == 'BR') {
            return "";
        }

        var parts = [];
        for (const child of node.childNodes) {
            parts.push(normalizeChildNodeText(child));
        }
        return parts.join('');
    })().replaceAll(trailing_character, "");
}

function normalizeChildNodeText(node) {
    var parts = [];
    if (interpretAsNewline(node)) {
        parts.push('\n');
    }

    if (node.childNodes.length == 0) {
        parts.push(node.textContent);
    }

    for (const child of node.childNodes) {
        parts.push(normalizeChildNodeText(child));
    }
    return parts.join('');
}

function interpretAsNewline(node) {
    if (!node.previousSibling || node.previousSibling.nodeName != 'BR') {
        if (node.nodeName == 'BR') {
            return true;
        } else if (node.nodeName == 'DIV' && node.textContent.length > 0) {
            return true;
        }
    }
    return false;
}

function endsWithTrailingCharacter(input) {
    if (!input) return false;
    return input.charCodeAt(input.len - 1) === trailing_character.charCodeAt(0);
}