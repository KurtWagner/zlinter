

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

    document.addEventListener('selectionchange', () => { overrideCursorPosition(); syncCursorToken() });
    inputElem.addEventListener('keypress', overrideEnterKeyPress);
    inputElem.addEventListener('input', syncLineNumbers);
    inputElem.addEventListener('input', syncTree);
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
        const highlightNodeClass = "tree__node--highlighted";
        [...document.getElementsByClassName(highlightNodeClass)].forEach(elem => elem.classList.remove(highlightNodeClass));

        const highlightFieldClass = "tree__node__field--highlighted";
        [...document.getElementsByClassName(highlightFieldClass)].forEach(elem => elem.classList.remove(highlightFieldClass));

        const tokenIndexAndToken = getSelectedToken();
        if (tokenIndexAndToken === null) return;
        const [token_i,] = tokenIndexAndToken;

        var lowestOverlappingNode = null;
        [...document.getElementsByClassName("tree__node")].forEach(elem => {
            const { firstToken, lastToken } = elem.dataset;
            if (firstToken === null || firstToken === undefined || lastToken === null || lastToken === undefined) return;

            if (token_i >= firstToken && token_i <= lastToken) {
                lowestOverlappingNode = elem;
            }
        });

        if (lowestOverlappingNode) {
            [...lowestOverlappingNode.getElementsByClassName("tree__node__field")].forEach(elem => {
                const { token } = elem.dataset;
                if (token === null || token === undefined) return;
                if (token != token_i) return;
                elem.classList.add(highlightFieldClass);
            });

            lowestOverlappingNode.classList.add(highlightNodeClass);
            lowestOverlappingNode.scrollIntoView({ block: "start" });
        }
    }

    function getSelectedToken() {
        if (!lastJson) return null;
        if (!insideOfInput(document.getSelection())) return null;

        const pos = getCursorPosition();
        for (let i = 0; i < lastJson.tokens.length; i++) {
            const token = lastJson.tokens[i];
            if (pos >= token.start && pos <= token.start + token.len) {
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

                    const token_tag_css_classes = {
                        "string_literal": "syntax-string-literal",
                        "number_literal": "syntax-number-literal",
                        "l_brace": "syntax-brace",
                        "r_brace": "syntax-brace",
                    };

                    if (token.tag.startsWith('keyword_')) {
                        classes.push("syntax-keyword");
                    } else if (token_tag_css_classes[token.tag]) {
                        classes.push(token_tag_css_classes[token.tag]);
                    }

                    const slice = textContent.slice(token.start, token.start + token.len);
                    syntax.push(`<span data-token-index="${tokenIndex}" class="${classes.join(' ')}">${slice}</span>`);

                    prev = token.start + token.len;
                }
                syntax.push(textContent.slice(prev));
                highlightElem.innerHTML = syntax
                    .join("")
                    // Syntax highlight comments:
                    // Instead we could use the tokenizer in zlinter but this
                    // is probably overkill for just syntax highlighting
                    // comments so we will try and make do with a simple regex.
                    .replaceAll(/\/\/[^\n]+/g, (comment) => `<span class="syntax-comment">${comment}</span>`)
                    + trailing_character;

                const treeRootElem = createTreeNode(textContent, {
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

                function createTreeNode(source, jsonObj) {
                    const div = document.createElement('div');
                    div.classList.add('tree__node');

                    div.dataset.firstToken = jsonObj.first_token;
                    div.dataset.lastToken = jsonObj.last_token;

                    for (const [key, val] of Object.entries(jsonObj)) {
                        if (["body", "first_token", "last_token"].includes(key)) continue;

                        const fieldDiv = document.createElement('div');
                        fieldDiv.classList.add('tree__node__field');

                        if (key == "tag") {
                            const tagSpan = document.createElement('span');
                            tagSpan.classList.add('tree__node__field__tag');
                            tagSpan.textContent = `.${val}`;
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
                                meta_span.textContent = `.${json.tokens[val].tag} "${tokenSlice(source, val)}"`;
                                fieldDiv.append(meta_span);
                            }
                        }
                        div.append(fieldDiv);
                    }

                    if (jsonObj["first_token"] !== jsonObj["last_token"]) {
                        const tokensFieldDiv = document.createElement('div');
                        tokensFieldDiv.classList.add('tree__node__field');

                        const tokensNameSpan = document.createElement('span');
                        tokensNameSpan.classList.add('tree__node__field__name');
                        tokensNameSpan.textContent = "tokens";
                        tokensFieldDiv.append(tokensNameSpan);
                        div.append(tokensFieldDiv);

                        for (let i = jsonObj["first_token"]; i <= jsonObj["last_token"]; i++) {
                            const tokenFieldDiv = document.createElement('div');
                            tokenFieldDiv.classList.add('tree__node__field');
                            tokenFieldDiv.classList.add('tree__node__field--indent');
                            tokenFieldDiv.dataset.token = i;

                            const token = json.tokens[i];
                            const tokenValueSpan = document.createElement('span');
                            tokenValueSpan.classList.add('tree__node__field__token');
                            tokenValueSpan.textContent = `.${token.tag}`;
                            tokenFieldDiv.append(tokenValueSpan);

                            const tokenMetaSpan = document.createElement('span');
                            tokenMetaSpan.classList.add('tree__node__field__meta');
                            tokenMetaSpan.textContent = `#${i} "${tokenSlice(source, i)}"`;
                            tokenFieldDiv.append(tokenMetaSpan);

                            div.append(tokenFieldDiv);
                        }
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
                            const treeNode = createTreeNode(source, child);
                            treeNode.classList.add('tree__node--indent');
                            div.append(treeNode)
                        }
                    }
                    return div;
                }

                function tokenSlice(source, tokenIndex) {
                    const token = json.tokens[tokenIndex];
                    if (!token) return '';
                    return source.slice(token.start, token.start + token.len);
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