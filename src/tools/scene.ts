import { z } from "zod";
import { ensureInsideProject, text, variantNote, type Register } from "../mcp/helpers.js";
import { EngineError } from "../engine/godot.js";

export function registerSceneTools(register: Register): void {
  register(
    "godot_scene",
    {
      title: "Сцены Godot",
      description:
        "Чтение сцен. mode=state — точное содержимое файла .tscn (только сохранённые свойства, ext_resource, связи): " +
        "лучший способ понять, что реально записано в сцене. mode=tree — дерево узлов (файл или живая игра), " +
        "mode=inspect — свойства/сигналы/методы узла, mode=create — создать новую сцену, mode=backups — бэкапы.",
      shape: {
        mode: z.enum(["state", "tree", "inspect", "create", "backups"]).default("state"),
        path: z.string().optional().describe("Путь к сцене .tscn. Для mode=tree без path берётся главная сцена"),
        source: z.enum(["file", "live"]).optional().describe("file — читать с диска, live — из запущенной игры"),
        node: z.string().optional().describe("Путь к узлу для mode=inspect"),
        props: z.enum(["none", "saved", "all", "custom"]).optional().describe("Какие свойства показывать в дереве"),
        prop_names: z.array(z.string()).optional().describe("Явный список свойств при props=custom"),
        prop_limit: z.number().int().min(1).max(200).optional(),
        max_depth: z.number().int().min(0).max(64).optional(),
        max_nodes: z.number().int().min(1).max(5000).optional(),
        property_mode: z.enum(["saved", "all", "custom"]).optional().describe("Режим свойств для inspect"),
        method_filter: z.string().optional().describe("Фильтр имён методов в inspect"),
        limit: z.number().int().min(1).max(2000).optional(),
        root_type: z.string().optional().describe("Тип корня для mode=create"),
        root_name: z.string().optional(),
        ops: z.array(z.record(z.string(), z.unknown())).optional().describe("Операции для mode=create (см. godot_scene_edit)"),
        overwrite: z.boolean().optional(),
      },
    },
    async (a, ctx) => {
      switch (a.mode) {
        case "state": {
          if (!a.path) throw new EngineError("Укажите path сцены", "bad_params");
          return text(await ctx.engine.call("scene.state", { path: a.path, props: true }));
        }
        case "tree":
          return text(
            await ctx.engine.call("scene.tree", {
              path: a.path,
              source: a.source ?? "file",
              props: a.props ?? "none",
              prop_names: a.prop_names ?? [],
              prop_limit: a.prop_limit ?? 24,
              max_depth: a.max_depth ?? 0,
              max_nodes: a.max_nodes ?? 600,
            }),
          );
        case "inspect": {
          if (a.source === "live" || (!a.path && a.node)) {
            return text(
              await ctx.engine.call("runtime.inspect", {
                node: a.node,
                mode: a.property_mode ?? "saved",
                props: [],
                method_filter: a.method_filter ?? "",
                limit: a.limit ?? 200,
              }),
            );
          }
          if (!a.path) throw new EngineError("Укажите path сцены", "bad_params");
          return text(
            await ctx.engine.call("scene.inspect", {
              path: a.path,
              node: a.node ?? "",
              mode: a.property_mode ?? "saved",
              props: [],
              method_filter: a.method_filter ?? "",
              limit: a.limit ?? 200,
            }),
          );
        }
        case "create": {
          if (!a.path) throw new EngineError("Укажите path новой сцены", "bad_params");
          ensureInsideProject(ctx, String(a.path));
          return text(
            await ctx.engine.call("scene.create", {
              path: a.path,
              root_type: a.root_type ?? "Node2D",
              root_name: a.root_name,
              ops: a.ops ?? [],
              overwrite: a.overwrite ?? false,
            }),
          );
        }
        default:
          return text(await ctx.engine.call("scene.backups", { file: a.path ?? "" }));
      }
    },
  );

  register(
    "godot_scene_edit",
    {
      title: "Редактирование сцены",
      description:
        "Транзакционное изменение .tscn пачкой операций. По умолчанию save=false (dry run: изменения применяются в памяти, " +
        "в лог попадает результат, файл не трогается) — сначала проверьте результат, затем повторите с save=true, при этом " +
        "автоматически создаётся бэкап в .mcp-backups. Операции: add_node, instantiate_scene, remove_node, duplicate, rename, " +
        "reparent, move, set_props, group, script, connect, disconnect, set_owner, set_meta. " +
        `Поля op: parent (для add_node/instantiate_scene), type, name, props, script, groups, index, path, to, signal, method, binds. ${variantNote}`,
      shape: {
        path: z.string().describe("Путь к сцене .tscn"),
        ops: z.array(z.record(z.string(), z.unknown())).describe("Список операций, применяемых по порядку"),
        save: z.boolean().optional().describe("Сохранить изменения (false = dry run)"),
        backup: z.boolean().optional().describe("Создавать бэкап перед записью (по умолчанию true)"),
        keep_backups: z.number().int().min(1).max(50).optional(),
      },
    },
    async (a, ctx) => {
      // Проверяем песочницу, но хосту отдаём res://-путь: он сам приводит путь к res://.
      ensureInsideProject(ctx, String(a.path));
      if (!Array.isArray(a.ops) || a.ops.length === 0) {
        throw new EngineError("Передайте непустой массив ops", "bad_params");
      }
      const out = await ctx.engine.call<Record<string, unknown>>("scene.apply_ops", {
        path: String(a.path),
        ops: a.ops,
        save: a.save ?? false,
        backup: a.backup ?? true,
        keep_backups: a.keep_backups ?? 5,
      });
      return text(out);
    },
  );
}
