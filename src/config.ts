import { existsSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export interface McpConfig {
  /** Абсолютный путь к корню Godot-проекта (в нём лежит project.godot). */
  projectRoot: string;
  /** Путь к исполняемому файлу Godot. */
  godotBin: string;
  /** Разрешено ли выполнять произвольный GDScript (runtime.eval). */
  allowEval: boolean;
  /** Таймауты, мс. */
  requestTimeoutMs: number;
  startTimeoutMs: number;
  stepTimeoutMs: number;
  cliTimeoutMs: number;
  /** Ограничения вывода. */
  maxLogLines: number;
  maxResponseBytes: number;
  /** Кэш class-API: ~/.cache/bismuth-mcp-godot */
  cacheDir: string;
  /** Порт TCP-моста; 0 — выбрать свободный. */
  bridgePort: number;
  /** Рендер по умолчанию для скриншотов. */
  render: boolean;
  /** Порт/драйверы для рендер-режима. */
  renderDisplayDriver: string;
  renderRenderingDriver: string;
  renderWindowPosition: string;
  renderWidth: number;
  renderHeight: number;
  verbose: boolean;
}

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) ? n : fallback;
}

function envBool(name: string, fallback: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return fallback;
  return ["1", "true", "yes", "on"].includes(raw.toLowerCase());
}

export function findProjectRoot(start: string): string {
  let dir = path.resolve(start);
  for (let i = 0; i < 12; i += 1) {
    if (existsSync(path.join(dir, "project.godot"))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(
    `Не найден project.godot (ищем вверх от ${path.resolve(start)}). ` +
      `Укажите корень проекта через переменную окружения GODOT_PROJECT.`,
  );
}

export function loadConfig(cwd = process.cwd()): McpConfig {
  const projectRoot = process.env.GODOT_PROJECT
    ? findProjectRoot(process.env.GODOT_PROJECT)
    : findProjectRoot(cwd);
  const cacheHome =
    process.env.XDG_CACHE_HOME ?? path.join(homedir(), ".cache");
  return {
    projectRoot,
    godotBin: process.env.GODOT_BIN ?? "godot",
    allowEval: envBool("GODOT_MCP_ALLOW_EVAL", false),
    requestTimeoutMs: envInt("GODOT_MCP_TIMEOUT_MS", 30_000),
    startTimeoutMs: envInt("GODOT_MCP_START_TIMEOUT_MS", 45_000),
    stepTimeoutMs: envInt("GODOT_MCP_STEP_TIMEOUT_MS", 60_000),
    cliTimeoutMs: envInt("GODOT_MCP_CLI_TIMEOUT_MS", 180_000),
    maxLogLines: envInt("GODOT_MCP_MAX_LOG_LINES", 4000),
    maxResponseBytes: envInt("GODOT_MCP_MAX_RESPONSE_BYTES", 8 * 1024 * 1024),
    cacheDir: process.env.GODOT_MCP_CACHE ?? path.join(cacheHome, "bismuth-mcp-godot"),
    bridgePort: envInt("GODOT_MCP_PORT", 0),
    render: envBool("GODOT_MCP_RENDER", false),
    renderDisplayDriver: process.env.GODOT_MCP_DISPLAY_DRIVER ?? "x11",
    renderRenderingDriver: process.env.GODOT_MCP_RENDERING_DRIVER ?? "opengl3",
    renderWindowPosition: process.env.GODOT_MCP_WINDOW_POSITION ?? "0,0",
    renderWidth: envInt("GODOT_MCP_RENDER_WIDTH", 1152),
    renderHeight: envInt("GODOT_MCP_RENDER_HEIGHT", 648),
    verbose: envBool("GODOT_MCP_VERBOSE", false),
  };
}

/** Убирает только префикс res://; ведущий "/" сохраняется, чтобы абсолютные пути не «подменялись». */
export function stripRes(target: string): string {
  return target.replace(/^res:\/\//, "");
}

/** Проверяет, что путь внутри корня проекта, и возвращает абсолютный путь. */
export function safeJoin(root: string, target: string): string {
  const abs = path.resolve(root, stripRes(target));
  const rel = path.relative(root, abs);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Путь ${target} выходит за пределы корня проекта ${root}`);
  }
  return abs;
}

/** Абсолютный путь -> res:// путь, с проверкой границ проекта. */
export function toResPath(root: string, target: string): string {
  const abs = safeJoin(root, target);
  return `res://${path.relative(root, abs).split(path.sep).join("/")}`;
}

export function isInside(root: string, abs: string): boolean {
  const rel = path.relative(root, path.resolve(abs));
  return !rel.startsWith("..") && !path.isAbsolute(rel);
}

export function fileSize(p: string): number {
  try {
    return statSync(p).size;
  } catch {
    return -1;
  }
}

export function readTextSafe(p: string): string {
  return readFileSync(p, "utf8");
}
