# zlinter vscode extension

Just playing around with the concept of an LSP.

To poke around with this:

1. Install dependencies (i'll probably submit these to source control but for now leaving out to avoid the noise):

   ```sh
   cd integrations/vscode
   npm install
   ```

2. Compile the extension:

   ```sh
   npm run compile
   ```

3. Open `integrations/vscode` in VSCode separately.

4. Press `F5` to launch a new vscode with a debugger running and the extentsion installed.

5. Open a `.zig` file from the zlinter project (it has a lint step)

6. In the output section select zlinter output

## Settings

- `zlinter.serverCommand`: defaults to `zig`
- `zlinter.serverArgs`: defaults to
  `["build", "lint", "--", "--mode", "lsp"]`
- `zlinter.projectRootOverride`: if set, skips project discovery and always
  starts the server from that directory
