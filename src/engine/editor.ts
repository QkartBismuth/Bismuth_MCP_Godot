import { spawn, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { createConnection, createServer } from "node:net";
import path from "node:path";
import type { McpConfig } from "../config.js";
import type { GodotEngine } from "./godot.js";
import { GdscriptLsp } from "../lsp/client.js";
import { sleep } from "./godot.js";

const DEFAULT_LSP_PORT = 6005;

export interface EditorState {
  running: boolean;
  lspConnected: boolean;
  lspPort: number | null;
  owned: boolean;
  pid: number | null;
  bridgeConnected: boolean;
  startedAt: number | null;
  lastError: string | null;
}

/**
 * Управление редактором Godot:
 *  - LSP: подключается к уже открытому редактору (порт 6005) либо поднимает свой headless-редактор;
 *  - мост: @tool-плагин в addons/ подключается к нашему TCP-мосту и выполняет команды редактора.
 */
export class EditorManager {
  private lsp: GdscriptLsp | null = null;
  private child: ChildProcessByStdio<null, Readable, Readable> | null = null;
  private state: EditorState = {
    running: false,
    lspConnected: false,
    lspPort: null,
    owned: false,
    pid: null,
    bridgeConnected: false,
    startedAt: null,
    lastError: null,
  };
  private starting: Promise<void> | null = null;

  constructor(
    private config: McpConfig,
    private engine: GodotEngine,
  ) {}

  getState(): EditorState {
    return { ...this.state, bridgeConnected: this.engine.hasEditorBridge() };
  }

  private async portOpen(port: number, timeoutMs = 700): Promise<boolean> {
    return new Promise((resolve) => {
      const socket = createConnection({ host: "127.0.0.1", port });
      const done = (ok: boolean) => {
        socket.destroy();
        resolve(ok);
      };
      socket.setTimeout(timeoutMs);
      socket.once("connect", () => done(true));
      socket.once("error", () => done(false));
      socket.once("timeout", () => done(false));
    });
  }

  /** Подключает LSP: сначала пробует существующий редактор, затем свой headless. */
  async ensureLsp(preferredPort = 0): Promise<GdscriptLsp> {
    if (this.lsp?.isReady()) return this.lsp;
    if (this.starting) {
      await this.starting;
      if (this.lsp?.isReady()) return this.lsp;
    }
    this.starting = (async () => {
      const external = process.env.GODOT_MCP_LSP_PORT ? Number.parseInt(process.env.GODOT_MCP_LSP_PORT, 10) : DEFAULT_LSP_PORT;
      let port = 0;
      if (await this.portOpen(external)) {
        port = external;
        this.state.owned = false;
        this.engine.logs.pushEvent(`LSP: используется уже открытый редактор на порту ${external}`, "info");
      } else {
        port = preferredPort || (await this.freePort());
        await this.spawnEditor(port);
        this.state.owned = true;
        const deadline = Date.now() + this.config.startTimeoutMs;
        let ready = false;
        while (Date.now() < deadline) {
          if (await this.portOpen(port)) {
            ready = true;
            break;
          }
          if (this.child?.exitCode !== null && this.child?.exitCode !== undefined) break;
          await sleep(200);
        }
        if (!ready) {
          const tail = this.engine.logs.list({ limit: 25 }).entries.map((e) => e.text).join("\n");
          this.state.lastError = "Редактор не поднял LSP";
          throw new Error(
            `Не удалось дождаться LSP на порту ${port} за ${Math.round(this.config.startTimeoutMs / 1000)} c.\n${tail}`,
          );
        }
      }
      const lsp = new GdscriptLsp("127.0.0.1", port, this.config.projectRoot);
      await lsp.connect();
      this.lsp = lsp;
      this.state.lspConnected = true;
      this.state.lspPort = port;
      this.state.running = true;
      this.state.lastError = null;
      this.engine.logs.pushEvent(`LSP подключён к 127.0.0.1:${port} (свой редактор: ${this.state.owned})`, "success");
    })();
    try {
      await this.starting;
    } finally {
      this.starting = null;
    }
    if (!this.lsp) throw new Error("LSP не инициализирован");
    return this.lsp;
  }

  /** Свободный TCP-порт на loopback (нужен для --lsp-port собственного редактора). */
  private freePort(): Promise<number> {
    return new Promise((resolve, reject) => {
      const probe = createServer();
      probe.on("error", reject);
      probe.listen(0, "127.0.0.1", () => {
        const addr = probe.address();
        const port = typeof addr === "object" && addr ? addr.port : 6100;
        probe.close(() => resolve(port));
      });
    });
  }

  private async spawnEditor(port: number): Promise<void> {
    const args = [
      "--headless",
      "--editor",
      "--path",
      this.config.projectRoot,
      "--lsp-port",
      String(port),
      "--quit-after",
      "100000",
    ];
    this.engine.logs.pushEvent(`Запуск редактора: ${this.config.godotBin} ${args.join(" ")}`, "info");
    const child = spawn(this.config.godotBin, args, {
      cwd: this.config.projectRoot,
      env: { ...process.env, GODOT_MCP_PORT: "", GODOT_MCP_TOKEN: "" },
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.child = child;
    this.state.pid = child.pid ?? null;
    this.state.startedAt = Date.now();
    child.stdout.on("data", (d: Buffer) => this.engine.logs.push("stdout", `[editor] ${d.toString("utf8")}`));
    child.stderr.on("data", (d: Buffer) => this.engine.logs.push("stderr", `[editor] ${d.toString("utf8")}`));
    child.on("exit", (code, signal) => {
      this.engine.logs.pushEvent(`Редактор завершился: code=${code} signal=${signal ?? "нет"}`);
      if (this.child === child) {
        this.child = null;
        this.state.running = false;
        this.state.lspConnected = false;
      }
    });
  }

  /** Команды к редактору через аддон-мост (нужен запущенный редактор с плагином). */
  async bridge(cmd: string, params: Record<string, unknown> = {}, timeoutMs = 20_000): Promise<unknown> {
    const peer = this.engine.editorPeer();
    if (!peer) {
      throw Object.assign(
        new Error(
          "Редактор не подключён к мосту. Установите аддон: godot_editor { mode: \"install_bridge\" }, " +
            "затем включите его в редакторе (Проект → Настройки плагинов → Bismuth MCP Godot Bridge) и перезапустите редактор.",
        ),
        { code: "no_editor_bridge" },
      );
    }
    return this.engine.bridge.request("editor", cmd, params, timeoutMs);
  }

  async stop(): Promise<void> {
    if (this.child) {
      this.child.kill("SIGTERM");
      await sleep(300);
      if (this.child.exitCode === null) this.child.kill("SIGKILL");
      this.child = null;
    }
    this.lsp?.close();
    this.lsp = null;
    this.state = { ...this.state, running: false, lspConnected: false, pid: null };
  }
}

export function defaultLspPort(): number {
  return DEFAULT_LSP_PORT;
}

export function projectPath(root: string, p: string): string {
  return path.resolve(root, p.replace(/^res:\/\//, ""));
}
