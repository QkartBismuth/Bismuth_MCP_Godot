import { z } from "zod";
import { text, type Ctx, type Register } from "../mcp/helpers.js";
import { EngineError } from "../engine/godot.js";

export function registerInspectTools(register: Register): void {
  register(
    "godot_class",
    {
      title: "Справка по API Godot",
      readOnly: true,
      description:
        "Справка по классам движка. mode=info — методы, свойства, сигналы, перечисления, константы класса " +
        "(структура берётся из ClassDB, точная и актуальная; mode=docs добавляет официальную документацию из " +
        "кэша --dump-extension-api-with-docs). mode=search — поиск по всему API (классы, методы, свойства, сигналы, enum) " +
        "и по глобальным классам проекта. mode=props — допустимые значения перечисляемого свойства. " +
        "mode=inheritors — кто наследуется от класса.",
      shape: {
        mode: z.enum(["info", "search", "props", "inheritors", "build_api_index"]).default("info"),
        class: z.string().optional().describe("Имя класса Godot, например CharacterBody2D"),
        property: z.string().optional().describe("Имя свойства для mode=props"),
        query: z.string().optional().describe("Поисковый запрос для mode=search"),
        kinds: z.array(z.enum(["class", "method", "property", "signal", "enum", "constant", "enum_value"])).optional(),
        include_docs: z.boolean().optional().describe("Добавить тексты документации (mode=info)"),
        no_inheritance: z.boolean().optional().describe("Только собственные члены класса"),
        sections: z.array(z.enum(["methods", "properties", "signals", "enums", "constants", "project_classes"])).optional(),
        limit: z.number().int().min(1).max(500).optional(),
      },
    },
    async (a, ctx) => {
      if (a.mode === "build_api_index") {
        const version = ctx.engine.version();
        const ok = await ctx.api.ensure(version, true);
        return text({ built: ok, meta: ctx.api.getMeta() });
      }
      if (a.mode === "search") {
        if (!a.query) throw new EngineError("Укажите query", "bad_params");
        const limit = a.limit ?? 40;
        const kinds = (a.kinds ?? ["class", "method", "property", "signal", "enum"]) as string[];
        const projectClasses = await ctx.engine
          .call<{ classes: Array<{ class: string; base: string; path: string }> }>("project.global_classes", {})
          .catch(() => ({ classes: [] as Array<{ class: string; base: string; path: string }> }));
        const engineResults = ctx.api.isLoaded()
          ? ctx.api.search(a.query, limit, kinds)
          : await ctx.engine
              .call<{ results: unknown[]; total: number }>("classdb.search", {
                query: a.query,
                limit,
                kinds,
              })
              .catch((e) => ({ results: [], total: 0, note: (e as Error).message }));
        const needle = a.query.toLowerCase();
        const projectHits = (projectClasses.classes ?? [])
          .filter((c) => kinds.includes("class") && c.class.toLowerCase().includes(needle))
          .map((c) => ({ class: c.class, kind: "project_class", name: c.class, detail: `extends ${c.base} (${c.path})` }));
        return text({
          query: a.query,
          api_index: ctx.api.isLoaded() ? "cached" : "classdb_only",
          ...(engineResults as object),
          results: [...(engineResults as any).results ?? [], ...projectHits].slice(0, limit),
        });
      }
      if (a.mode === "props") {
        if (!a.class || !a.property) throw new EngineError("Укажите class и property", "bad_params");
        return text(await ctx.engine.call("classdb.props", { class: a.class, property: a.property }));
      }
      if (a.mode === "inheritors") {
        if (!a.class) throw new EngineError("Укажите class", "bad_params");
        return text(await ctx.engine.call("classdb.inheritors", { class: a.class }));
      }
      if (!a.class) throw new EngineError("Укажите class", "bad_params");
      const sections = (a.sections ?? ["methods", "properties", "signals", "enums", "constants"]) as string[];
      const structural = await ctx.engine.call<Record<string, unknown>>("classdb.info", {
        class: a.class,
        no_inheritance: a.no_inheritance ?? false,
        sections,
      });
      let docs: unknown;
      if (a.include_docs) {
        if (!ctx.api.isLoaded()) await ctx.api.ensure(ctx.engine.version());
        const doc = ctx.api.describe(a.class, !(a.no_inheritance ?? false));
        if (doc) {
          docs = {
            brief: doc.brief,
            description: doc.description,
            methods: pickDocs(doc.methods),
            properties: pickDocs(doc.properties),
            signals: pickDocs(doc.signals),
            enums: doc.enums,
            constants: pickDocs(doc.constants),
          };
        }
      }
      return text({ ...structural, docs });
    },
  );

  register(
    "godot_script",
    {
      title: "Скрипты GDScript",
      description:
        "Работа со скриптами. mode=info — метаданные (базовый класс, class_name, tool, строки), mode=symbols — структура: " +
        "функции, сигналы, переменные (с @export и значениями по умолчанию), константы, enum, docstring и номера строк, " +
        "mode=read — текст (с диапазоном строк), mode=references — где вызывается символ в .gd файлах проекта.",
      shape: {
        mode: z.enum(["info", "symbols", "read", "references"]).default("symbols"),
        path: z.string().optional().describe("Путь к .gd файлу (обязателен, кроме mode=references)"),
        symbol: z.string().optional().describe("Имя функции/символа для mode=references"),
        from_line: z.number().int().min(1).optional(),
        to_line: z.number().int().min(0).optional(),
        dirs: z.array(z.string()).optional().describe("Каталоги поиска для references, по умолчанию res://"),
        include_definition: z.boolean().optional(),
        limit: z.number().int().min(1).max(500).optional(),
      },
    },
    async (a, ctx) => {
      if (a.mode === "references") {
        if (!a.symbol) throw new EngineError("Укажите symbol", "bad_params");
        return text(
          await ctx.engine.call("script.find_references", {
            symbol: a.symbol,
            dirs: a.dirs ?? ["res://"],
            include_definition: a.include_definition ?? true,
            limit: a.limit ?? 60,
          }),
        );
      }
      if (!a.path) throw new EngineError("Укажите path к .gd файлу", "bad_params");
      const cmd = a.mode === "info" ? "script.info" : a.mode === "read" ? "script.read" : "script.symbols";
      return text(
        await ctx.engine.call(cmd, {
          path: a.path,
          from_line: a.from_line ?? 1,
          to_line: a.to_line ?? 0,
        }),
      );
    },
  );

  register(
    "godot_script_check",
    {
      title: "Проверка скриптов",
      description:
        "Проверяет синтаксис и компиляцию .gd файлов (godot --check-only) и/или загружает проект в headless-режиме, " +
        "чтобы поймать ошибки времени выполнения при инициализации. Возвращает список ошибок с файлами и строками. " +
        "Используйте после массового редактирования скриптов.",
      shape: {
        paths: z.array(z.string()).optional().describe("Конкретные .gd файлы; по умолчанию — все скрипты проекта"),
        dir: z.string().optional().describe("Каталог для сканирования, по умолчанию res://"),
        boot_check: z.boolean().optional().describe("Дополнительно загрузить проект в headless и собрать ошибки инициализации"),
        boot_frames: z.number().int().min(1).max(600).optional(),
        limit: z.number().int().min(1).max(5000).optional(),
      },
    },
    async (a, ctx) => {
      const started = Date.now();
      const files = Array.isArray(a.paths) && a.paths.length ? (a.paths as string[]) : await listScripts(ctx, a.dir);
      const errors: Array<{ file: string; line?: number; message: string }> = [];
      let checked = 0;
      // Пакетная проверка: один запуск Godot на группу файлов невозможен для --check-only,
      // поэтому проверяем скрипты последовательно, но с ограничением параллелизма.
      const batchSize = 8;
      for (let i = 0; i < files.length; i += batchSize) {
        const batch = files.slice(i, i + batchSize);
        const results = await Promise.all(
          batch.map(async (f) => {
            const res = await ctx.engine.runCli(["--headless", "--check-only", "-s", f], { timeout: 60_000 });
            return { file: f, res };
          }),
        );
        for (const { file, res } of results) {
          checked += 1;
          const out = `${res.stdout}\n${res.stderr}`;
          if (res.code !== 0 || /SCRIPT ERROR|Parse Error|error/i.test(out)) {
            for (const line of out.split("\n")) {
              if (!/error|Parse Error|SCRIPT ERROR/i.test(line)) continue;
              const m = /(res:\/\/[^\s:)]+):(\d+)/.exec(line);
              errors.push({ file: m?.[1] ?? file, line: m?.[2] ? Number(m[2]) : undefined, message: line.trim().slice(0, 300) });
            }
          }
        }
      }
      const out: Record<string, unknown> = {
        checked_scripts: checked,
        files: Array.isArray(a.paths) ? (a.paths as string[]) : undefined,
        errors: errors.slice(0, a.limit ?? 200),
        error_count: errors.length,
        duration_ms: Date.now() - started,
        ok: errors.length === 0,
      };
      if (a.boot_check) {
        const boot = await ctx.engine
          .call<Record<string, unknown>>("runtime.start", {})
          .catch((e) => ({ error: (e as Error).message }));
        const frames = a.boot_frames ?? 5;
        const stepDone = ctx.engine.waitForEvent("step_complete", (d: any) => d?.status?.frame !== undefined, 60_000);
        await ctx.engine.call("runtime.step", { frames }).catch((e) => ({ error: (e as Error).message }));
        await stepDone.catch(() => undefined);
        const logs = ctx.engine.logs.list({ limit: 200, errorsOnly: true });
        out.boot = { start: boot, errors: logs.entries.map((e) => e.text).slice(0, 60) };
        await ctx.engine.call("runtime.stop", {}).catch(() => undefined);
      }
      return text(out);
    },
  );
}

async function listScripts(ctx: Ctx, dir?: string): Promise<string[]> {
  const res = await ctx.engine.call<{ files: Array<{ path: string }> }>("file.list", {
    dir: dir ?? "res://",
    include: ["*.gd"],
    limit: 5000,
  });
  return (res.files ?? [])
    .map((f) => f.path)
    .filter((p) => !p.includes("/.mcp/") && !p.startsWith("res://addons/gut/"));
}

function pickDocs<T extends { brief?: string; description?: string }>(bag: Record<string, T>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(bag)) {
    if (!v) continue;
    out[k] = { brief: v.brief ?? "", description: (v.description ?? "").slice(0, 1500) };
  }
  return out;
}
