import { execFile } from "node:child_process";
import { access } from "node:fs/promises";
import * as path from "node:path";
import { promisify } from "node:util";
import * as vscode from "vscode";
import {
    LanguageClient,
    LanguageClientOptions,
    ServerOptions,
    State,
    Trace,
} from "vscode-languageclient/node";

const execFileAsync = promisify(execFile);
const zigLanguageId = "zig";
const buildFileName = "build.zig";

type StartedClient = {
    readonly client: LanguageClient;
    readonly outputChannel: vscode.OutputChannel;
    readonly traceChannel: vscode.OutputChannel;
};

const clients = new Map<string, StartedClient>();
const projectLookup = new Map<string, Promise<string | undefined>>();
const lintStepLookup = new Map<string, Promise<boolean>>();

export function activate(context: vscode.ExtensionContext) {
    context.subscriptions.push({
        dispose: () => {
            for (const startedClient of clients.values()) {
                startedClient.outputChannel.dispose();
                startedClient.traceChannel.dispose();
                void startedClient.client.stop();
            }
            clients.clear();
        },
    });

    context.subscriptions.push(
        vscode.workspace.onDidOpenTextDocument((document) => {
            void ensureClientForDocument(document);
        }),
    );
    context.subscriptions.push(
        vscode.window.onDidChangeActiveTextEditor((editor) => {
            if (!editor) return;
            void ensureClientForDocument(editor.document);
        }),
    );

    for (const document of vscode.workspace.textDocuments) {
        void ensureClientForDocument(document);
    }
}

export function deactivate(): Thenable<void> {
    return Promise.all(
        [...clients.values()].map((startedClient) => startedClient.client.stop()),
    ).then(() => undefined);
}

async function ensureClientForDocument(
    document: vscode.TextDocument,
): Promise<void> {
    if (document.languageId !== zigLanguageId || document.uri.scheme !== "file") {
        return;
    }

    const projectRoot = await findProjectRootForDocument(document);
    if (!projectRoot) {
        return;
    }

    if (clients.has(projectRoot)) {
        const startedClient = clients.get(projectRoot);
        startedClient?.outputChannel.appendLine(
            `Opened Zig file: ${document.uri.fsPath}`,
        );
        return;
    }

    const startedClient = startClient(projectRoot);
    clients.set(projectRoot, startedClient);
    startedClient.outputChannel.appendLine(
        `Opened Zig file: ${document.uri.fsPath}`,
    );
}

async function findProjectRootForDocument(
    document: vscode.TextDocument,
): Promise<string | undefined> {
    const configuration = vscode.workspace.getConfiguration("zlinter");
    const configuredRoot = configuration.get<string>("projectRootOverride")?.trim();
    if (configuredRoot) {
        return configuredRoot;
    }

    const startingDirectory = path.dirname(document.uri.fsPath);
    const cachedLookup = projectLookup.get(startingDirectory);
    if (cachedLookup) {
        return cachedLookup;
    }

    const lookup = findNearestLintCapableProjectRoot(startingDirectory);
    projectLookup.set(startingDirectory, lookup);
    return lookup;
}

async function findNearestLintCapableProjectRoot(
    startingDirectory: string,
): Promise<string | undefined> {
    for (
        let currentDirectory = startingDirectory;
        ;
        currentDirectory = path.dirname(currentDirectory)
    ) {
        const buildFilePath = path.join(currentDirectory, buildFileName);
        if (await fileExists(buildFilePath)) {
            if (await directoryHasLintStep(currentDirectory)) {
                return currentDirectory;
            }
        }

        const parentDirectory = path.dirname(currentDirectory);
        if (parentDirectory === currentDirectory) {
            return undefined;
        }
    }
}

async function directoryHasLintStep(directory: string): Promise<boolean> {
    const cachedLookup = lintStepLookup.get(directory);
    if (cachedLookup) {
        return cachedLookup;
    }

    const lookup = probeDirectoryForLintStep(directory);
    lintStepLookup.set(directory, lookup);
    return lookup;
}

// TODO: make this less shit / rethink how this should work but for now just poking about
// Probably look in a zlinter config file in the project or something...
async function probeDirectoryForLintStep(directory: string): Promise<boolean> {
    const configuration = vscode.workspace.getConfiguration("zlinter");
    const serverCommand = configuration.get<string>("serverCommand") ?? "zig";

    try {
        const result = await execFileAsync(serverCommand, ["build", "-l"], {
            cwd: directory,
        });
        const lines = `${result.stdout}\n${result.stderr}`.split(/\r?\n/);
        return lines.some((line) => /^\s*lint(?:\s|$)/.test(line));
    } catch {
        return false;
    }
}

function startClient(projectRoot: string): StartedClient {
    const configuration = vscode.workspace.getConfiguration("zlinter");
    const serverCommand = configuration.get<string>("serverCommand") ?? "zig";
    const serverArgs = configuration.get<string[]>("serverArgs") ?? [
        "build",
        "lint",
        "--",
        "--mode",
        "lsp",
    ];
    const projectLabel = path.basename(projectRoot) || projectRoot;
    const outputChannel = vscode.window.createOutputChannel(
        `zlinter: ${projectLabel}`,
    );
    const traceChannel = vscode.window.createOutputChannel(
        `zlinter trace: ${projectLabel}`,
    );

    const serverOptions: ServerOptions = {
        command: serverCommand,
        args: serverArgs,
        options: {
            cwd: projectRoot,
        },
    };

    const clientOptions: LanguageClientOptions = {
        documentSelector: [
            {
                scheme: "file",
                language: zigLanguageId,
                pattern: `${normalizePathForGlob(projectRoot)}/**/*.zig`,
            },
        ],
        outputChannel,
        traceOutputChannel: traceChannel,
        synchronize: {
            configurationSection: "zlinter",
            fileEvents: vscode.workspace.createFileSystemWatcher(
                `${normalizePathForGlob(projectRoot)}/**/zlinter.zon`,
            ),
        },
        workspaceFolder: vscode.workspace.getWorkspaceFolder(
            vscode.Uri.file(projectRoot),
        ),
    };

    const client = new LanguageClient(
        `zlinter:${projectRoot}`,
        `zlinter (${projectLabel})`,
        serverOptions,
        clientOptions,
    );

    outputChannel.appendLine(
        `Starting zlinter LSP: ${serverCommand} ${serverArgs.join(" ")} (cwd: ${projectRoot})`,
    );
    client.setTrace(Trace.Verbose);
    client.onDidChangeState((event) => {
        outputChannel.appendLine(
            `Client state changed: ${formatState(event.oldState)} -> ${formatState(event.newState)}`,
        );
    });

    void client.start();

    return {
        client,
        outputChannel,
        traceChannel,
    };
}

async function fileExists(filePath: string): Promise<boolean> {
    try {
        await access(filePath);
        return true;
    } catch {
        return false;
    }
}

function normalizePathForGlob(filePath: string): string {
    return filePath.split(path.sep).join("/");
}

function formatState(state: State): string {
    switch (state) {
        case State.Starting:
            return "Starting";
        case State.Running:
            return "Running";
        case State.Stopped:
            return "Stopped";
    }
}
