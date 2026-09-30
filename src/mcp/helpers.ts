import { existsSync, readFileSync } from "node:fs";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { safeJoin } from "../config.js";
import type { CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { z } from "zod";
import type { McpConfig } from "../config.js";
import { EngineError, GodotEngine } from "../engine/godot.js";
import { ApiIndex } from "../engine/apiIndex.js";

export interface Ctx {
  config: McpConfig;
  engine: GodotEngine;
  api: ApiIndex;
}

export function createCtx(config: McpConfig): Ctx {
  const engine = new GodotEngine(config);
  const api = new ApiIndex(config.cacheDir, (args, cwd) =>
    engine.runCli(args, { cwd, timeout: config.cliTimeoutMs }),
  );
  return { config, engine, api };
}

export function text(data: unknown): CallToolResult {
  const body = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  return { content: [{ type: "text", text: body }] };
}

export function textWithImage(data: unknown, imagePath: string): CallToolResult {
  const body = typeof data === "string" ? data : JSON.stringify(data, null, 2);
  const content: CallToolResult["content"] = [{ type: "text", text: body }];
  if (existsSync(imagePath)) {
    try {
      const buf = readFileSync(imagePath);
      if (buf.length <= 6 * 1024 * 1024) {
        content.push({ type: "image", data: buf.toString("base64"), mimeType: "image/png" });
      }
    } catch {
      /* файл недоступен — вернём только путь */
    }
  }
  return { content };
}

export function failure(err: unknown): CallToolResult {
  if (err instanceof EngineError) {
    const parts = [`Ошибка [${err.code}]: ${err.message}`];
    if (err.hint) parts.push(`Подсказка: ${err.hint}`);
    return { content: [{ type: "text", text: parts.join("\n\n") }], isError: true };
  }
  const e = err as Error & { code?: string; hint?: string };
  const code = e?.code ? ` [${e.code}]` : "";
  const hint = e?.hint ? `\n\nПодсказка: ${e.hint}` : "";
  return { content: [{ type: "text", text: `Ошибка${code}: ${e?.message ?? String(err)}${hint}` }], isError: true };
}

export type ToolShape = Record<string, z.ZodTypeAny>;

export interface ToolDef {
  title: string;
  description: string;
  shape: ToolShape;
  readOnly?: boolean;
  idempotent?: boolean;
  /** Инструмент работает и без открытого Godot-проекта (godot_status, scaffold). */
  allowNoProject?: boolean;
}

export type ToolArgs = Record<string, any>;

export type ToolHandler = (args: ToolArgs, ctx: Ctx) => Promise<CallToolResult>;

export type Register = (name: string, def: ToolDef, handler: ToolHandler) => void;

export function defineTool(server: McpServer, name: string, opts: ToolDef, handler: ToolHandler, ctx: Ctx): void {
  server.registerTool(
    name,
    {
      title: opts.title,
      description: opts.description,
      inputSchema: opts.shape,
      annotations: {
        title: opts.title,
        readOnlyHint: opts.readOnly ?? false,
        destructiveHint: !(opts.readOnly ?? false),
        idempotentHint: opts.idempotent ?? false,
        openWorldHint: false,
      },
    },
    (async (args: ToolArgs) => {
      try {
        if (ctx.config.projectError && !opts.allowNoProject) throw noProjectError(ctx);
        return await handler(args ?? {}, ctx);
      } catch (err) {
        return failure(err);
      }
    }) as never,
  );
}

/** Общие схемы аргументов. */
export const args = {
  path: z.string().describe("Путь внутри проекта: res://scenes/main.tscn или scenes/main.tscn"),
  node: z.string().describe("Путь к узлу относительно корня сцены/рантайма, например Player/Sprite2D или /root/Main/Player"),
  props: z.array(z.string()).optional().describe("Явный список имён свойств. По умолчанию — сохраняемые (STORAGE) свойства"),
  limit: z.number().int().min(1).max(5000).optional(),
  save: z.boolean().optional().describe("Сохранить изменения на диск"),
};

/**
 * Ошибка для инструментов, которым нужен открытый Godot-проект.
 * Возникает, когда сервер запущен в каталоге без project.godot
 * и переменная GODOT_PROJECT не задана.
 */
export function noProjectError(ctx: Ctx): EngineError {
  return new EngineError(
    `Godot-проект не найден: ${ctx.config.projectError}`,
    "no_project",
    "Откройте каталог Godot-проекта в редакторе агента либо задайте GODOT_PROJECT " +
      "в переменных окружения MCP-сервера (например GODOT_PROJECT=/путь/к/проекту).",
  );
}

/** Проверяет песочницу и возвращает абсолютный путь. */
export function ensureInsideProject(ctx: Ctx, target: string): string {
  try {
    return safeJoin(ctx.config.projectRoot, target);
  } catch {
    throw new EngineError(
      `Путь ${target} находится вне корня проекта ${ctx.config.projectRoot}`,
      "sandbox",
      "Все файловые операции ограничены каталогом Godot-проекта.",
    );
  }
}

/** Значения Variant описываются объектами вида {"$": "Vector2", "x": 1, "y": 2}. */
export const variantNote =
  "Значения свойств: примитивы (число/строка/bool), вложенные пути вида \"theme/colors/font_color\", " +
  "строки вида \"Vector2(10, 20)\" или объекты {\"$\":\"Vector2\",\"x\":10,\"y\":20}, {\"$\":\"Color\",\"hex\":\"#ff8800\"}, " +
  "ссылки на ресурсы {\"path\":\"res://icon.svg\"} или {\"$\":\"ClassRef\",\"class\":\"PointLight2D\"}.";
