import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig, type McpConfig } from "../src/config.js";
import { createCtx, type Ctx } from "../src/mcp/helpers.js";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const FIXTURE = path.join(HERE, "fixtures", "demo-project");

/** Копия фикстуры во временном каталоге: тесты не трогают репозиторий. */
export function makeProject(): string {
  const dir = mkdtempSync(path.join(tmpdir(), "bismuth-mcp-godot-test-"));
  cpSync(FIXTURE, dir, { recursive: true });
  for (const junk of [".godot", ".mcp", ".mcp-backups", ".mcp-shots", "addons", "t"]) {
    rmSync(path.join(dir, junk), { recursive: true, force: true });
  }
  return dir;
}

export function godotAvailable(): boolean {
  try {
    const cfg = loadConfig(FIXTURE);
    const res = loadConfigSafe(cfg);
    return res;
  } catch {
    return false;
  }
}

function loadConfigSafe(cfg: McpConfig): boolean {
  try {
    // Проверяем, что бинарь отвечает.
    const { spawnSync } = require("node:child_process") as typeof import("node:child_process");
    const res = spawnSync(cfg.godotBin, ["--version"], { encoding: "utf8", timeout: 15_000 });
    return res.status === 0;
  } catch {
    return false;
  }
}

export interface Harness {
  ctx: Ctx;
  dir: string;
  dispose: () => Promise<void>;
}

export async function startHarness(opts: { verbose?: boolean; waitImport?: boolean } = {}): Promise<Harness> {
  const dir = makeProject();
  process.env.GODOT_PROJECT = dir;
  const cfg = loadConfig(dir);
  cfg.verbose = opts.verbose ?? false;
  const ctx = createCtx(cfg);
  if (opts.waitImport !== false) await waitForImport(ctx);
  return {
    ctx,
    dir,
    dispose: async () => {
      await ctx.engine.dispose();
      delete process.env.GODOT_PROJECT;
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

/**
 * Ждёт завершения фонового импорта проекта.
 * Сервер запускает `godot --import` в фоне, поэтому копия фикстуры
 * (без каталога .godot) готова к работе не сразу.
 */
export async function waitForImport(ctx: { config: { projectRoot: string }; engine: { startImportInBackground: () => void; importInfo: () => Record<string, unknown> } }, timeoutMs = 120_000): Promise<void> {
  if (existsSync(path.join(ctx.config.projectRoot, ".godot"))) return;
  ctx.engine.startImportInBackground();
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const state = String(ctx.engine.importInfo().state ?? "");
    if (state === "ready") return;
    if (state === "failed") throw new Error(`Импорт фикстуры не удался: ${String(ctx.engine.importInfo().error ?? "?")}`);
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`Импорт фикстуры не завершился за ${timeoutMs} мс`);
}

export function sceneText(dir: string, rel: string): string {
  return readFileSync(path.join(dir, rel), "utf8");
}

export function writeScene(dir: string, rel: string, text: string): void {
  writeFileSync(path.join(dir, rel), text, "utf8");
}

export function projectHas(dir: string, rel: string): boolean {
  return existsSync(path.join(dir, rel));
}
