import { existsSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { ensureInsideProject, text, textWithImage, type Ctx, type Register } from "../mcp/helpers.js";
import { EditorManager } from "../engine/editor.js";
import { EngineError } from "../engine/godot.js";

const managers = new WeakMap<Ctx, EditorManager>();

export function editorManager(ctx: Ctx): EditorManager {
  let m = managers.get(ctx);
  if (!m) {
    m = new EditorManager(ctx.config, ctx.engine);
    managers.set(ctx, m);
  }
  return m;
}

export function registerEditorTools(register: Register): void {
  register(
    "godot_lsp",
    {
      title: "Диагностика GDScript (LSP)",
      description:
        "Доступ к встроенному языковому серверу Godot (GDScript LSP). mode=diagnostics — ошибки и предупреждения по файлам " +
        "(файл должен существовать; ставится в очередь didOpen), mode=hover — документация символа по позиции, " +
        "mode=definition — переход к определению, mode=completion — автодополнение, mode=symbols — структура файла " +
        "по данным редактора, mode=references — использования символа, mode=status — состояние LSP. " +
        "Если редактор не открыт, сервер поднимает свой headless-редактор (первый вызов занимает до десятка секунд). " +
        "Позиции: line и character 1-based.",
      shape: {
        mode: z.enum(["status", "diagnostics", "hover", "definition", "completion", "symbols", "references"]).default("diagnostics"),
        path: z.string().optional().describe("Путь к .gd файлу (обязателен, кроме mode=status)"),
        paths: z.array(z.string()).optional().describe("Несколько файлов для mode=diagnostics"),
        dir: z.string().optional().describe("Каталог для сканирования .gd, если paths не задан"),
        line: z.number().int().min(1).optional(),
        character: z.number().int().min(1).optional(),
        include_declaration: z.boolean().optional(),
        limit: z.number().int().min(1).max(500).optional(),
      },
    },
    async (a, ctx) => {
      const mgr = editorManager(ctx);
      if (a.mode === "status") {
        return text({ editor: mgr.getState(), hint: "Вызовите любой другой режим, чтобы подключиться к LSP" });
      }
      if (a.mode === "diagnostics" && a.path) {
        const lsp = await mgr.ensureLsp();
        const abs = ensureInsideProject(ctx, String(a.path));
        return text({ file: abs, diagnostics: await lsp.openFile(abs), count: (await lsp.openFile(abs)).length });
      }
      const lsp = await mgr.ensureLsp();
      if (a.mode === "diagnostics") {
        const files = Array.isArray(a.paths) && a.paths.length ? (a.paths as string[]) : await listGd(ctx, a.dir);
        const results: Array<{ file: string; diagnostics: unknown[] }> = [];
        let errorCount = 0;
        let warnCount = 0;
        for (const f of files.slice(0, a.limit ?? 120)) {
          const abs = ensureInsideProject(ctx, f);
          const diags = await lsp.openFile(abs, 350);
          if (!diags.length) continue;
          errorCount += diags.filter((d) => d.severity === "error").length;
          warnCount += diags.filter((d) => d.severity === "warning").length;
          results.push({ file: f, diagnostics: diags });
        }
        return text({ files_checked: files.length, error_count: errorCount, warning_count: warnCount, results });
      }
      if (!a.path) throw new EngineError("Укажите path", "bad_params");
      const abs = ensureInsideProject(ctx, String(a.path));
      const line = a.line ?? 1;
      const character = a.character ?? 1;
      switch (a.mode) {
        case "hover":
          return text(await lsp.hover(abs, line, character));
        case "definition":
          return text({ definition: await lsp.definition(abs, line, character) });
        case "completion":
          return text(await lsp.completion(abs, line, character));
        case "symbols":
          return text(await lsp.symbols(abs));
        default:
          return text({ references: await lsp.references(abs, line, character, a.include_declaration ?? false) });
      }
    },
  );

  register(
    "godot_editor",
    {
      title: "Редактор Godot",
      description:
        "Управление редактором через аддон-мост (нужен запущенный редактор с плагином Bismuth MCP Godot Bridge). " +
        "mode=status — состояние, mode=install_bridge — установить аддон в проект (изменяет проект!), " +
        "mode=open_scene — открыть сцену в редакторе, mode=save — сохранить открытую сцену, mode=reload — перечитать сцену с диска, " +
        "mode=log — журнал редактора, mode=run — запустить проект из редактора, mode=stop — остановить, " +
        "mode=edit_scene — применить операции к открытой в редакторе сцене, mode=screenshot — снимок окна редактора.",
      shape: {
        mode: z.enum([
          "status",
          "install_bridge",
          "open_scene",
          "save",
          "reload",
          "log",
          "run",
          "stop",
          "edit_scene",
          "screenshot",
        ]).default("status"),
        path: z.string().optional().describe("Путь к сцене для open_scene"),
        ops: z.array(z.record(z.string(), z.unknown())).optional().describe("Операции для edit_scene (см. godot_scene_edit)"),
        limit: z.number().int().min(1).max(1000).optional(),
        timeout_ms: z.number().int().min(1000).max(300000).optional(),
      },
    },
    async (a, ctx) => {
      const mgr = editorManager(ctx);
      switch (a.mode) {
        case "status":
          return text({
            editor: mgr.getState(),
            bridge_required: "res://addons/bismuth_mcp_godot/plugin.cfg",
            installed: existsSync(path.join(ctx.config.projectRoot, "addons", "bismuth_mcp_godot", "plugin.cfg")),
          });
        case "install_bridge": {
          const res = ctx.engine.installEditorBridge();
          return text({
            ...res,
            next_step:
              "Перезапустите редактор и включите плагин: Проект → Настройки плагинов → Bismuth MCP Godot Bridge. " +
              "Плагин подключится к MCP-серверу автоматически (порт и токен он берёт из res://.mcp/bridge.json).",
          });
        }
        case "log":
          return text(await mgr.bridge("log", { limit: a.limit ?? 100 }));
        case "screenshot": {
          const res = (await mgr.bridge("screenshot", { timeout: a.timeout_ms ?? 5000 })) as any;
          return textWithImage(res, res?.real_path ?? "");
        }
        case "edit_scene": {
          if (!Array.isArray(a.ops) || a.ops.length === 0) throw new EngineError("Передайте ops", "bad_params");
          return text(await mgr.bridge("edit_scene", { ops: a.ops }, a.timeout_ms ?? 30_000));
        }
        default: {
          const cmd =
            a.mode === "open_scene"
              ? "open_scene"
              : a.mode === "save"
                ? "save_scene"
                : a.mode === "reload"
                  ? "reload_scene"
                  : a.mode === "run"
                    ? "run_project"
                    : "stop_project";
          if (cmd === "open_scene") {
            if (!a.path) throw new EngineError("Укажите path сцены", "bad_params");
            ensureInsideProject(ctx, String(a.path));
          }
          return text(await mgr.bridge(cmd, { path: a.path }, a.timeout_ms ?? 30_000));
        }
      }
    },
  );
}

async function listGd(ctx: Ctx, dir?: string): Promise<string[]> {
  const res = await ctx.engine.call<{ files: Array<{ path: string }> }>("file.list", {
    dir: dir ?? "res://",
    include: ["*.gd"],
    limit: 5000,
  });
  return (res.files ?? []).map((f) => f.path).filter((p) => !p.includes("/.mcp/"));
}
