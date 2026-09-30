import { spawn, spawnSync, type ChildProcessByStdio } from "node:child_process";
import type { Readable } from "node:stream";
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import type { McpConfig } from "../config.js";
import { BridgeServer } from "./bridge.js";
import { LogBuffer } from "./logs.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
/** Корень пакета: dist/ или корень репозитория при запуске из исходников. */
export const PACKAGE_ROOT = (() => {
  let dir = HERE;
  for (let i = 0; i < 6; i += 1) {
    if (existsSync(path.join(dir, "godot", "host", "host.gd"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error("Не найден каталог godot/host относительно " + HERE);
})();

export const HOST_DIR = "godot/host";
export const BRIDGE_DIR = "godot/editor_bridge";
export const HOST_TARGET = ".mcp";
export const SCRIPT_PROTOCOL = 1;

export interface GodotVersion {
  full: string;
  major: number;
  minor: number;
  patch: number;
  status: string;
}

export interface HostOptions {
  /** Требовать рендер-режим: если хост уже headless — перезапустить с display-драйвером. */
  ensureRender?: boolean;
  scene?: string;
  maxFps?: number;
  restart?: boolean;
}

export interface HostState {
  running: boolean;
  render: boolean;
  pid: number | null;
  startedAt: number | null;
  display: string;
  version: GodotVersion | null;
  lastError: string | null;
  restarts: number;
}

export class EngineError extends Error {
  constructor(
    message: string,
    readonly code: string,
    readonly hint?: string,
  ) {
    super(message);
  }
}

export class GodotEngine {
  readonly logs: LogBuffer;
  readonly bridge: BridgeServer;
  private child: ChildProcessByStdio<null, Readable, Readable> | null = null;
  private state: HostState = {
    running: false,
    render: false,
    pid: null,
    startedAt: null,
    display: "unknown",
    version: null,
    lastError: null,
    restarts: 0,
  };
  private versionCache: GodotVersion | null = null;
  private importChecked = false;
  private startPromise: Promise<void> | null = null;
  private onUnbound: Array<() => void> = [];

  constructor(private config: McpConfig) {
    this.logs = new LogBuffer(config.maxLogLines, config.verbose);
    this.bridge = new BridgeServer(this.logs);
    this.bridge.on((e) => {
      if (e.type === "hello" && e.peer.kind === "host") {
        this.state.running = true;
        this.state.pid = e.peer.hello.pid ?? null;
        this.state.display = e.peer.hello.display ?? "unknown";
        this.state.startedAt = Date.now();
        this.state.lastError = null;
        if (e.peer.hello.engine?.version_full_name) {
          this.state.version = parseVersion(String(e.peer.hello.engine.version_full_name));
        }
        this.logs.pushEvent(`Хост готов (pid=${this.state.pid}, display=${this.state.display})`, "success");
      }
      if (e.type === "close" && e.peer.kind === "host") {
        this.state.running = false;
        this.state.pid = null;
        this.logs.pushEvent("Хост отключился", "warning");
      }
      if (e.type === "event" && e.peer.kind === "editor" && e.event === "editor_connected") {
        this.logs.pushEvent("Редактор подключился к мосту", "success");
      }
    });
  }

  bindProcessCleanup(): void {
    const kill = () => {
      this.killHost("SIGKILL");
      void this.bridge.close();
    };
    process.once("exit", kill);
    process.once("SIGINT", kill);
    process.once("SIGTERM", kill);
    this.onUnbound.push(() => process.off("exit", kill));
  }

  get projectRoot(): string {
    return this.config.projectRoot;
  }

  /** Подключён ли сейчас редактор через аддон-мост. */
  hasEditorBridge(): boolean {
    return this.bridge.getPeer("editor") !== undefined;
  }

  editorPeer() {
    return this.bridge.getPeer("editor");
  }

  get cfg(): McpConfig {
    return this.config;
  }

  getState(): HostState {
    return { ...this.state, version: this.state.version ?? this.versionCache };
  }

  /** Бинарь Godot и его версия (с кэшем). */
  version(): GodotVersion {
    if (this.versionCache) return this.versionCache;
    const res = spawnSync(this.config.godotBin, ["--version"], { encoding: "utf8", timeout: 15_000 });
    if (res.error || res.status !== 0) {
      throw new EngineError(
        `Не удалось запустить "${this.config.godotBin} --version": ${res.error?.message ?? res.stderr ?? res.status}`,
        "godot_not_found",
        "Укажите путь к бинарю в переменной окружения GODOT_BIN (например GODOT_BIN=/usr/bin/godot).",
      );
    }
    const line = (res.stdout || res.stderr).trim().split("\n")[0] ?? "";
    this.versionCache = parseVersion(line);
    this.state.version = this.versionCache;
    return this.versionCache;
  }

  /** Раскладывает GDScript хоста в <project>/.mcp (вне системы контроля версий). */
  installHostScripts(): { dir: string; files: string[] } {
    const target = path.join(this.config.projectRoot, HOST_TARGET);
    const src = path.join(PACKAGE_ROOT, HOST_DIR);
    mkdirSync(target, { recursive: true });
    const files: string[] = [];
    const copy = (rel: string) => {
      const from = path.join(src, rel);
      const to = path.join(target, rel);
      mkdirSync(path.dirname(to), { recursive: true });
      copyFileSync(from, to);
      files.push(`${HOST_TARGET}/${rel}`);
    };
    copy("host.gd");
    copy("variant.gd");
    copy("commands/cmd_core.gd");
    copy("commands/cmd_classdb.gd");
    copy("commands/cmd_resource.gd");
    copy("commands/cmd_scene.gd");
    copy("commands/cmd_script.gd");
    copy("commands/cmd_runtime.gd");
    copy("commands/cmd_capture.gd");
    writeFileSync(path.join(target, ".gdignore"), "# Файлы служебного MCP-хоста: редактор их не сканирует.\n", "utf8");
    writeFileSync(
      path.join(target, "version.json"),
      JSON.stringify({ protocol: SCRIPT_PROTOCOL, installed_at: new Date().toISOString() }, null, 2),
      "utf8",
    );
    return { dir: target, files };
  }

  removeHostScripts(): void {
    const target = path.join(this.config.projectRoot, HOST_TARGET);
    if (existsSync(target)) rmSync(target, { recursive: true, force: true });
  }

  /** Записывает параметры подключения для аддона-моста (плагин переподключается сам). */
  writeBridgeFile(): string {
    const dir = path.join(this.config.projectRoot, HOST_TARGET);
    mkdirSync(dir, { recursive: true });
    const file = path.join(dir, "bridge.json");
    writeFileSync(
      file,
      JSON.stringify({ port: this.bridge.port || 0, token: this.bridge.token, protocol: SCRIPT_PROTOCOL }, null, 2),
      "utf8",
    );
    return file;
  }

  /** Устанавливает аддон-мост в проект (нужен для работы с открытым редактором). */
  installEditorBridge(): { addon: string; enabled: boolean; bridge_file: string } {
    const src = path.join(PACKAGE_ROOT, BRIDGE_DIR);
    const dst = path.join(this.config.projectRoot, "addons", "bismuth_mcp_godot");
    mkdirSync(dst, { recursive: true });
    for (const name of readdirSync(src)) {
      const from = path.join(src, name);
      if (statSync(from).isDirectory()) continue;
      copyFileSync(from, path.join(dst, name));
    }
    const bridgeFile = this.writeBridgeFile();
    // Аддон использует res://.mcp/variant.gd, поэтому хостовые скрипты должны лежать в проекте.
    this.installHostScripts();
    const projectFile = path.join(this.config.projectRoot, "project.godot");
    const text = existsSync(projectFile) ? readFileSync(projectFile, "utf8") : "";
    const entry = '"res://addons/bismuth_mcp_godot/plugin.cfg"';
    const enabled = /enabled\s*=\s*PackedStringArray\(([^)]*)\)/.exec(text);
    if (enabled) {
      if (!enabled[1]?.includes("bismuth_mcp_godot/plugin.cfg")) {
        const list = (enabled[1] ?? "").trim();
        const newList = list.length ? `${list}, ${entry}` : entry;
        writeFileSync(projectFile, text.replace(/enabled\s*=\s*PackedStringArray\([^)]*\)/, `enabled=PackedStringArray(${newList})`), "utf8");
      }
    } else {
      const section = `\n[editor_plugins]\n\nenabled=PackedStringArray(${entry})\n`;
      writeFileSync(projectFile, `${text.replace(/\s*$/, "\n")}${section}`, "utf8");
    }
    return { addon: "res://addons/bismuth_mcp_godot", enabled: true, bridge_file: bridgeFile };
  }

  private async ensureImported(): Promise<void> {
    if (this.importChecked) return;
    this.importChecked = true;
    const godotDir = path.join(this.config.projectRoot, ".godot");
    if (existsSync(godotDir)) return;
    this.logs.pushEvent("Проект не импортирован, запускаю godot --import", "info");
    const res = await this.runCli(["--headless", "--import"], { timeout: this.config.startTimeoutMs * 3 });
    if (res.code !== 0 || !existsSync(godotDir)) {
      const tail = `${res.stdout}\n${res.stderr}`.split("\n").filter((l) => l.trim()).slice(-15).join("\n");
      throw new EngineError(
        `Импорт проекта не удался (код ${res.code}). Возможно, project.godot повреждён или нет прав на запись.\n${tail}`,
        "import_failed",
      );
    }
    this.logs.pushEvent("Импорт проекта завершён", "success");
  }

  private godotArgs(opts: { render: boolean }): string[] {
    const args = ["--path", this.config.projectRoot];
    if (opts.render) {
      args.push(
        "--display-driver",
        this.config.renderDisplayDriver,
        "--rendering-driver",
        this.config.renderRenderingDriver,
        "--audio-driver",
        "Dummy",
        "--windowed",
        "--position",
        this.config.renderWindowPosition,
        "--resolution",
        `${this.config.renderWidth}x${this.config.renderHeight}`,
        "--disable-vsync",
      );
    } else {
      args.push("--headless");
    }
    args.push("--script", `res://${HOST_TARGET}/host.gd`);
    return args;
  }

  /**
   * Поднимает хост (идемпотентно). Уже запущенный хост не перезапускается,
   * кроме случая апгрейда до рендер-режима или «протухшего» процесса.
   */
  async ensureHost(opts: HostOptions = {}): Promise<void> {
    if (this.state.running) {
      const needsRender = opts.ensureRender === true && !this.state.render;
      const stale = this.state.startedAt !== null && Date.now() - this.state.startedAt > 30 * 60_000;
      if (needsRender || stale) await this.restartHost(needsRender);
      return;
    }
    if (this.startPromise) {
      await this.startPromise;
      if (this.state.running) {
        if (opts.ensureRender === true && !this.state.render) await this.restartHost(true);
        return;
      }
    }
    const wantRender = opts.ensureRender ?? this.config.render;
    this.startPromise = this.startHost(wantRender).finally(() => {
      this.startPromise = null;
    });
    await this.startPromise;
  }

  private async restartHost(render: boolean): Promise<void> {
    this.logs.pushEvent(`Перезапуск хоста (render=${render})`, "info");
    this.killHost("SIGTERM");
    await waitFor(() => !this.state.running, 5000);
    this.state.restarts += 1;
    await this.startHost(render);
  }

  private async startHost(render: boolean): Promise<void> {
    await this.ensureImported();
    this.installHostScripts();
    if (this.bridge.port === 0) await this.bridge.listen(this.config.bridgePort);
    // Аддон редактора читает порт/токен отсюда и переподключается при смене.
    this.writeBridgeFile();
    this.version();
    const args = this.godotArgs({ render });
    this.logs.pushEvent(`Запуск: ${this.config.godotBin} ${args.join(" ")}`, "info");
    const child = spawn(this.config.godotBin, args, {
      cwd: this.config.projectRoot,
      env: {
        ...process.env,
        GODOT_MCP_PORT: String(this.bridge.port),
        GODOT_MCP_TOKEN: this.bridge.token,
        GODOT_MCP_PROTOCOL: String(SCRIPT_PROTOCOL),
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.child = child;
    this.state.render = render;
    this.state.running = false;
    child.stdout.on("data", (d: Buffer) => this.logs.push("stdout", d.toString("utf8")));
    child.stderr.on("data", (d: Buffer) => this.logs.push("stderr", d.toString("utf8")));
    child.on("error", (err) => {
      this.state.lastError = err.message;
      this.logs.pushEvent(`Ошибка запуска Godot: ${err.message}`, "error");
    });
    child.on("exit", (code, signal) => {
      this.logs.flush();
      this.logs.pushEvent(`Процесс Godot завершён: code=${code} signal=${signal ?? "нет"}`);
      this.child = null;
      this.state.running = false;
      this.state.pid = null;
      this.bridge.rejectAllPending("Процесс Godot завершился");
    });

    const deadline = Date.now() + this.config.startTimeoutMs;
    while (Date.now() < deadline) {
      if (this.state.running) return;
      if (child.exitCode !== null) break;
      await sleep(50);
    }
    const tail = this.logs.list({ limit: 40, errorsOnly: false }).entries.map((e) => e.text).join("\n");
    const code = child.exitCode;
    this.killHost("SIGKILL");
    throw new EngineError(
      `Хост Godot не подключился за ${Math.round(this.config.startTimeoutMs / 1000)} c (код выхода: ${code ?? "нет"}).\n` +
        `Последние строки вывода:\n${tail}`,
      "host_start_failed",
      "Проверьте, что проект импортируется: godot --headless --import --path <проект>",
    );
  }

  /** Однократный запуск CLI Godot (импорт, экспорт, проверка скриптов). */
  runCli(args: string[], opts: { timeout?: number; cwd?: string } = {}): Promise<{ code: number; stdout: string; stderr: string; timedOut: boolean }> {
    const timeout = opts.timeout ?? this.config.cliTimeoutMs;
    return new Promise((resolve, reject) => {
      const child = spawn(this.config.godotBin, args, {
        cwd: opts.cwd ?? this.config.projectRoot,
        env: { ...process.env, GODOT_MCP_PORT: "", GODOT_MCP_TOKEN: "" },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      let timedOut = false;
      const timer = setTimeout(() => {
        timedOut = true;
        child.kill("SIGKILL");
      }, timeout);
      child.stdout.on("data", (d: Buffer) => {
        stdout += d.toString("utf8");
        if (stdout.length > 40 * 1024 * 1024) stdout = stdout.slice(-20 * 1024 * 1024);
      });
      child.stderr.on("data", (d: Buffer) => {
        stderr += d.toString("utf8");
        if (stderr.length > 40 * 1024 * 1024) stderr = stderr.slice(-20 * 1024 * 1024);
      });
      child.on("error", (err) => {
        clearTimeout(timer);
        reject(new EngineError(err.message, "godot_not_found"));
      });
      child.on("close", (code) => {
        clearTimeout(timer);
        resolve({ code: code ?? -1, stdout, stderr, timedOut });
      });
    });
  }

  async stopHost(): Promise<void> {
    if (!this.child) return;
    this.killHost("SIGTERM");
    await waitFor(() => this.child === null, 5000);
  }

  killHost(signal: NodeJS.Signals = "SIGTERM"): void {
    if (this.child && this.child.exitCode === null) {
      try {
        this.child.kill(signal);
      } catch {
        /* процесс уже мёртв */
      }
    }
  }

  /** Вызов команды на хосте с авторестартом при падении. */
  async call<T = unknown>(cmd: string, params: Record<string, unknown> = {}, opts: { timeoutMs?: number; ensureRender?: boolean; retry?: boolean } = {}): Promise<T> {
    await this.ensureHost({ ensureRender: opts.ensureRender });
    try {
      return (await this.bridge.request("host", cmd, params, opts.timeoutMs ?? this.config.requestTimeoutMs)) as T;
    } catch (err) {
      const canRetry = opts.retry ?? true;
      if (!canRetry || !isConnectionError(err)) throw err;
      this.logs.pushEvent(`Хост недоступен во время ${cmd}, перезапускаю`, "warning");
      await this.restartHost(opts.ensureRender ?? this.config.render);
      return (await this.bridge.request("host", cmd, params, opts.timeoutMs ?? this.config.requestTimeoutMs)) as T;
    }
  }

  /** Ожидание события от хоста. */
  waitForEvent(name: string, predicate: (data: any) => boolean, timeoutMs: number): Promise<any> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        off();
        reject(new Error(`Таймаут ${timeoutMs} мс в ожидании события ${name}`));
      }, timeoutMs);
      const off = this.bridge.on((e) => {
        if (e.type === "event" && e.event === name && e.peer.kind === "host") {
          let match = false;
          try {
            match = predicate(e.data);
          } catch {
            match = false;
          }
          if (match) {
            clearTimeout(timer);
            off();
            resolve(e.data);
          }
        }
      });
    });
  }

  async dispose(): Promise<void> {
    await this.stopHost();
    await this.bridge.close();
    for (const f of this.onUnbound) f();
  }
}

function isConnectionError(err: unknown): boolean {
  const e = err as Error & { code?: string };
  return (
    e?.message?.includes("Нет подключённого пиера") === true ||
    e?.message?.includes("завершился") === true ||
    e?.code === "ECONNRESET" ||
    e?.code === "EPIPE"
  );
}

export function parseVersion(full: string): GodotVersion {
  const m = /(\d+)\.(\d+)\.?(\d+)?\.?([a-z0-9]*)/i.exec(full);
  return {
    full: full.trim(),
    major: m?.[1] ? Number.parseInt(m[1], 10) : 0,
    minor: m?.[2] ? Number.parseInt(m[2], 10) : 0,
    patch: m?.[3] ? Number.parseInt(m[3], 10) : 0,
    status: m?.[4] ?? "",
  };
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function waitFor(pred: () => boolean, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (pred()) return true;
    await sleep(50);
  }
  return pred();
}
