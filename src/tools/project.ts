import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { z } from "zod";
import { ensureInsideProject, text, variantNote, type Ctx, type Register } from "../mcp/helpers.js";
import { EngineError } from "../engine/godot.js";

export function registerProjectTools(register: Register): void {
  register(
    "godot_status",
    {
      title: "Статус Godot",
      readOnly: true,
      description:
        "Состояние MCP-сервера и движка: версия Godot, корень проекта, запущен ли headless-хост, режим рендера, " +
        "готов ли импорт проекта, доступные возможности (скриншоты, LSP, редактор), лимиты. Вызывайте в начале работы.",
      shape: {
        refresh_api: z.boolean().optional().describe("Также пересобрать индекс документации API (медленно, ~7 c)"),
      },
    },
    async (a, ctx) => {
      const version = ctx.engine.version();
      const state = ctx.engine.getState();
      if (a.refresh_api) await ctx.api.ensure(version, true);
      // Не поднимаем хост только ради статуса: если он уже есть — забираем живые данные.
      const info = state.running
        ? await ctx.engine.call<Record<string, unknown>>("host.info", {}, { retry: false }).catch((e) => ({ error: (e as Error).message }))
        : { note: "хост не запущен; он поднимется при первом обращении к проектным инструментам" };
      const hostDir = path.join(ctx.config.projectRoot, ".mcp");
      const apiMeta = ctx.api.getMeta();
      return text({
        ok: true,
        engine: { ...version, binary: ctx.config.godotBin },
        project: {
          root: ctx.config.projectRoot,
          host_scripts: existsSync(path.join(hostDir, "host.gd")),
          main_scene: readMainScene(ctx.config.projectRoot),
        },
        host: state,
        host_info: info,
        api_index: apiMeta
          ? { ...apiMeta, file_mb: Number((ctx.api.fileSize() / 1048576).toFixed(1)) }
          : { loaded: false, hint: "Вызовите godot_class { mode: \"build_api_index\": true } или godot_status { refresh_api: true } для загрузки документации" },
        capabilities: {
          screenshots: state.running ? state.display !== "headless" : ctx.config.render,
          runtime: true,
          editor_bridge: ctx.engine.hasEditorBridge(),
          lsp: true,
          export_templates: existsSync(exportTemplatesDir(version.full)),
        },
        limits: {
          request_timeout_ms: ctx.config.requestTimeoutMs,
          max_log_lines: ctx.config.maxLogLines,
          allow_eval: ctx.config.allowEval,
        },
      });
    },
  );

  register(
    "godot_project_info",
    {
      title: "Информация о проекте",
      readOnly: true,
      description:
        "Сводка по Godot-проекту: имя, версия/features, главная сцена, автолоаны, слои физики/рендера, input-карта, " +
        "плагины редактора, глобальные классы (class_name), пресеты экспорта.",
      shape: {
        input_actions: z.boolean().optional().describe("Также вернуть полную карту ввода (может быть большой)"),
        autoloads: z.boolean().optional(),
        global_classes: z.boolean().optional().describe("Вернуть список скриптов с class_name"),
      },
    },
    async (a, ctx) => {
      const out = await ctx.engine.call<Record<string, unknown>>("project.info", {});
      if (a.input_actions) {
        out.input_actions = (await ctx.engine.call("project.input_actions", {})) as unknown;
      }
      if (a.autoloads) {
        out.autoloads = (await ctx.engine.call("project.autoloads", {})) as unknown;
      }
      if (a.global_classes) {
        out.global_class_list = (await ctx.engine.call("project.global_classes", {})) as unknown;
      }
      return text(out);
    },
  );

  register(
    "godot_project_settings",
    {
      title: "Настройки проекта",
      description:
        "Чтение и запись настроек проекта (project.godot): list (все ключи, опционально по префиксу), get (конкретные ключи), " +
        "set (запись значений с правильной типизацией, save=true сохраняет файл). Ключи указываются без секции: \"display/window/size/viewport_width\".",
      shape: {
        mode: z.enum(["list", "get", "set"]).describe("Режим операции"),
        prefix: z.string().optional().describe("Фильтр ключей по префиксу для mode=list"),
        keys: z.array(z.string()).optional().describe("Ключи для mode=get"),
        items: z
          .array(z.object({ key: z.string(), value: z.unknown() }).passthrough())
          .optional()
          .describe("Пары ключ/значение для mode:set"),
        save: z.boolean().optional().describe("Сохранить project.godot после записи (по умолчанию только в памяти)"),
        limit: z.number().int().min(1).max(5000).optional(),
      },
    },
    async (a, ctx) => text(await ctx.engine.call("project.settings", a as Record<string, unknown>)),
  );

  register(
    "godot_files",
    {
      title: "Файлы проекта",
      description:
        "Работа с файлами проекта. mode=list — дерево файлов с фильтрами-глобами (*.gd, res://scenes/**), mode=read — чтение текста " +
        "(с диапазоном строк), mode=write — запись (создаёт каталоги), mode=restore — восстановление файла из бэкапа .mcp-backups. " +
        "Выход за пределы корня проекта запрещён.",
      shape: {
        mode: z.enum(["list", "read", "write", "stat", "restore"]),
        path: z.string().optional().describe("Путь к файлу (для read/write/stat/restore) или каталогу (для list)"),
        include: z.array(z.string()).optional().describe("Глобы файлов для list, например [\"*.gd\"]"),
        exclude: z.array(z.string()).optional(),
        recursive: z.boolean().optional(),
        directories: z.boolean().optional().describe("Включить список каталогов"),
        max_depth: z.number().int().min(1).max(32).optional(),
        content: z.string().optional().describe("Содержимое для mode=write"),
        append: z.boolean().optional(),
        offset: z.number().int().min(0).optional().describe("Смещение в байтах для mode=read"),
        max_bytes: z.number().int().min(1).optional(),
        backup: z.string().optional().describe("Имя файла бэкапа для mode=restore"),
        limit: z.number().int().min(1).max(5000).optional(),
      },
    },
    async (a, ctx) => {
      const mode = String(a.mode);
      if (mode === "restore") {
        if (!a.backup || !a.path) throw new EngineError("Укажите path и backup", "bad_params");
        return text(await ctx.engine.call("scene.restore", { path: a.path, backup: a.backup }));
      }
      if (mode === "read" || mode === "stat") {
        if (!a.path) throw new EngineError("Укажите path", "bad_params");
        ensureInsideProject(ctx, String(a.path));
      }
      if (mode === "write") {
        if (!a.path) throw new EngineError("Укажите path", "bad_params");
        const abs = ensureInsideProject(ctx, String(a.path));
        const before = existsSync(abs) ? readFileSync(abs, "utf8") : null;
        if (before !== null && a.content !== undefined) {
          const backupDir = path.join(ctx.config.projectRoot, ".mcp-backups");
          mkdirSync(backupDir, { recursive: true });
          const stamp = new Date().toISOString().replace(/[:.]/g, "-");
          writeFileSync(path.join(backupDir, `${stamp}_${path.basename(abs)}.bak`), before, "utf8");
        }
      }
      return text(await ctx.engine.call(`file.${mode}`, a as Record<string, unknown>));
    },
  );

  register(
    "godot_assets",
    {
      title: "Поиск ресурсов",
      readOnly: true,
      description:
        "Поиск ассетов проекта по имени/пути и типу ресурса (Texture2D, PackedScene, Script, AudioStream, Font, Shader...) " +
        "с uid, размером и признаком импорта. Дополнительно mode=references находит, где ресурс упоминается в текстовых файлах.",
      shape: {
        mode: z.enum(["search", "info", "references"]).default("search"),
        query: z.string().optional().describe("Подстрока пути или имени файла"),
        type: z.string().optional().describe("Тип ресурса Godot, например Texture2D или PackedScene"),
        dir: z.string().optional().describe("Каталог поиска, по умолчанию res://"),
        path: z.string().optional().describe("Точный путь для mode=info/references"),
        limit: z.number().int().min(1).max(2000).optional(),
        include_meta: z.boolean().optional(),
      },
    },
    async (a, ctx) => {
      if (a.mode === "info") {
        if (!a.path) throw new EngineError("Укажите path", "bad_params");
        return text(await ctx.engine.call("resource.info", { path: a.path }));
      }
      if (a.mode === "references") {
        if (!a.path) throw new EngineError("Укажите path", "bad_params");
        return text(await ctx.engine.call("resource.references", { path: a.path, limit: a.limit }));
      }
      return text(await ctx.engine.call("resource.assets", a as Record<string, unknown>));
    },
  );

  register(
    "godot_resource",
    {
      title: "Ресурсы Godot",
      description:
        "Чтение и изменение любого Resource (.tres, темы, шейдеры, ресурсы сцен). mode=info — метаданные и зависимости, " +
        "mode=get — свойства, mode=set — запись свойств (save=true сохраняет файл, save_as — в новый), mode=create — создание ресурса. " +
        variantNote,
      shape: {
        mode: z.enum(["info", "get", "set", "create"]).default("get"),
        path: z.string().describe("Путь к ресурсу"),
        type: z.string().optional().describe("Класс ресурса для mode=create, например Theme или Environment"),
        base: z.string().optional().describe("Базовый ресурс для дублирования в mode=create"),
        script: z.string().optional().describe("Скрипт для mode=create"),
        items: z.array(z.object({ key: z.string(), value: z.unknown() }).passthrough()).optional(),
        props: z.array(z.string()).optional(),
        property_mode: z.enum(["saved", "all", "custom"]).optional().describe("Какие свойства читать в mode=get"),
        save: z.boolean().optional(),
        save_as: z.string().optional(),
        limit: z.number().int().min(1).max(2000).optional(),
      },
    },
    async (a, ctx) => {
      const mode = String(a.mode);
      if (mode === "info") return text(await ctx.engine.call("resource.info", a as Record<string, unknown>));
      if (mode === "get")
        return text(
          await ctx.engine.call("resource.get", {
            path: a.path,
            props: a.props ?? [],
            mode: a.property_mode ?? "saved",
            limit: a.limit ?? 200,
          }),
        );
      if (mode === "set") {
        if (a.path) ensureInsideProject(ctx, String(a.path));
        if (a.save_as) ensureInsideProject(ctx, String(a.save_as));
        return text(await ctx.engine.call("resource.set", a as Record<string, unknown>));
      }
      return text(await ctx.engine.call("resource.create", a as Record<string, unknown>));
    },
  );

  register(
    "godot_project_import",
    {
      title: "Импорт проекта",
      description:
        "Запускает godot --headless --import: пересканирует файловую систему проекта, импортирует/переимпортирует ассеты, " +
        "генерирует uid. Нужно после добавления новых файлов ассетов перед их использованием. Возвращает сводку и хвост вывода.",
      shape: {
        force: z.boolean().optional().describe("Принудительный реимпорт (--import без --editor)"),
        timeout_ms: z.number().int().min(5000).max(1800000).optional(),
      },
    },
    async (a, ctx) => {
      const started = Date.now();
      const res = await ctx.engine.runCli(["--headless", "--import"], {
        timeout: a.timeout_ms ?? ctx.config.cliTimeoutMs,
      });
      const output = `${res.stdout}\n${res.stderr}`.split("\n").filter((l) => l.trim());
      return text({
        code: res.code,
        timed_out: res.timedOut,
        duration_ms: Date.now() - started,
        imported: output.filter((l) => /import|reimport/i.test(l)).slice(0, 60),
        errors: output.filter((l) => /error|fail/i.test(l)).slice(0, 60),
        output_tail: output.slice(-40),
      });
    },
  );

  register(
    "godot_project_scaffold",
    {
      title: "Создание проекта",
      description:
        "Создаёт новый Godot 4 проект в указанном каталоге: project.godot (с корректными features), .gitignore, main.tscn, " +
        "скрипт игрока и каталоги. Используйте для старта с нуля — текущий проект сервера при этом не меняется.",
      shape: {
        dir: z.string().describe("Каталог нового проекта"),
        name: z.string().optional().describe("Имя проекта (по умолчанию — имя каталога)"),
        main_scene_type: z.enum(["Node2D", "Node3D", "Control"]).default("Node2D"),
        renderer: z.enum(["forward_plus", "mobile", "gl_compatibility"]).default("forward_plus"),
        overwrite: z.boolean().optional(),
        with_input_map: z.boolean().optional().describe("Добавить базовые действия ввода (move_left/right, jump, ui_accept)"),
        physics_2d: z.enum(["default", "platformer"]).default("platformer"),
      },
    },
    async (a, ctx) => {
      const target = path.resolve(ctx.config.projectRoot, String(a.dir));
      if (existsSync(path.join(target, "project.godot")) && !a.overwrite) {
        throw new EngineError(`В ${target} уже есть project.godot (передайте overwrite=true)`, "exists");
      }
      mkdirSync(target, { recursive: true });
      for (const d of ["scenes", "scripts", "assets", "addons"]) mkdirSync(path.join(target, d), { recursive: true });
      const name = String(a.name ?? path.basename(target));
      const physics = a.physics_2d === "platformer" ? 1 : 0;
      const godotFile = `; Конфигурация проекта (создано Bismuth_MCP_Godot)
config_version=5

[application]

config/name="${name}"
config/description=""
run/main_scene="res://scenes/main.tscn"
config/features=PackedStringArray("4.4", "Forward Plus")
config/icon="res://icon.svg"

[display]

window/size/viewport_width=1152
window/size/viewport_height=648
window/stretch/mode="canvas_items"

[physics]

${physics === 1 ? "2d/default_gravity=1400.0\ncommon/physics_ticks_per_second=60" : "3d/default_gravity=9.8"}

[rendering]

renderer/rendering_method="${a.renderer}"
renderer/rendering_method.mobile="${a.renderer}"
textures/vram_compression/import_etc2_astc=true
`;
      writeFileSync(path.join(target, "project.godot"), godotFile, "utf8");
      writeFileSync(
        path.join(target, ".gitignore"),
        "# Godot 4\n.godot/\n.import/\nexport.cfg\nexport_presets.cfg\n\n# Служебные файлы Bismuth_MCP_Godot\n.mcp/\n.mcp-backups/\n.mcp-shots/\n",
        "utf8",
      );
      const mainType = String(a.main_scene_type);
      const childNode = mainType === "Control" ? "" : mainType === "Node2D" ? "\n[sub_resource type=\"LabelSettings\" id=\"LabelSettings_1\"]\n" : "";
      void childNode;
      writeFileSync(
        path.join(target, "scenes", "main.tscn"),
        `[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/main.gd" id="1_main"]

[node name="Main" type="${mainType}"]
script = ExtResource("1_main")
`,
        "utf8",
      );
      writeFileSync(
        path.join(target, "scripts", "main.gd"),
        `extends ${mainType}


func _ready() -> void:
\tprint("[${name}] ready")
`,
        "utf8",
      );
      writeFileSync(
        path.join(target, "icon.svg"),
        `<svg xmlns="http://www.w3.org/2000/svg" width="128" height="128" viewBox="0 0 128 128"><rect width="128" height="128" rx="16" fill="#478cbf"/><circle cx="64" cy="64" r="34" fill="#ffffff"/></svg>\n`,
        "utf8",
      );
      if (a.with_input_map) {
        const file = path.join(target, "project.godot");
        const text = readFileSync(file, "utf8");
        const input = `
[input]

move_left={
"deadzone": 0.5,
"events": [Object(InputEventKey,"physical_keycode":65)]
}
move_right={
"deadzone": 0.5,
"events": [Object(InputEventKey,"physical_keycode":68)]
}
jump={
"deadzone": 0.5,
"events": [Object(InputEventKey,"physical_keycode":32)]
}
`;
        writeFileSync(file, `${text}${input}`, "utf8");
      }
      const importRes = await ctx.engine.runCli(["--headless", "--import", "--path", target], {
        cwd: target,
        timeout: ctx.config.startTimeoutMs * 2,
      });
      return text({
        created: target,
        name,
        main_scene_type: mainType,
        import_code: importRes.code,
        files: readdirSync(target),
        next_step: `Откройте каталог как проект: cd ${target} && godot .`,
      });
    },
  );

  register(
    "godot_export",
    {
      title: "Экспорт и тесты",
      description:
        "Сборка: mode=presets — список пресетов экспорта, mode=export — экспорт по пресету (pack или бинарник), " +
        "mode=test — запуск тестов в headless (GUT или пользовательский раннер) с разбором вывода.",
      shape: {
        mode: z.enum(["presets", "export", "test"]).default("presets"),
        preset: z.string().optional().describe("Имя пресета (или индекс из mode=presets)"),
        target: z.string().optional().describe("Путь результата: builds/game.x86_64 или builds/game.pck"),
        release: z.boolean().optional().describe("release-сборка (по умолчанию debug)"),
        pack_only: z.boolean().optional().describe("Только .pck без исполняемого файла"),
        test_command: z.array(z.string()).optional().describe("Своя команда запуска тестов, например [\"addons/gut/gut_cmdln.gd\"]"),
        timeout_ms: z.number().int().min(5000).max(1800000).optional(),
      },
    },
    async (a, ctx) => {
      if (a.mode === "presets") {
        return text(await ctx.engine.call("project.export_presets", {}));
      }
      if (a.mode === "test") {
        return text(await runTests(ctx, a));
      }
      const presets = (await ctx.engine.call<{ presets: Array<{ id: string; name: string; platform: string }> }>(
        "project.export_presets",
        {},
      )) as any;
      if (!a.preset) throw new EngineError("Укажите preset (см. mode=presets)", "bad_params");
      const found = presets.presets.find((p: { id: string; name: string }) => p.id === a.preset || p.name === a.preset);
      if (!found) {
        throw new EngineError(
          `Пресет "${a.preset}" не найден. Доступны: ${presets.presets.map((p: { id: string }) => p.id).join(", ") || "(нет export_presets.cfg)"}`,
          "not_found",
        );
      }
      const target = String(a.target ?? (a.pack_only ? "builds/game.pck" : `builds/${found.name || "game"}`));
      const abs = ensureInsideProject(ctx, target);
      mkdirSync(path.dirname(abs), { recursive: true });
      const flag = a.pack_only ? "--export-pack" : a.release ? "--export-release" : "--export-debug";
      const res = await ctx.engine.runCli(["--headless", flag, found.id, abs], {
        timeout: a.timeout_ms ?? ctx.config.cliTimeoutMs,
      });
      const all = `${res.stdout}\n${res.stderr}`.split("\n");
      return text({
        preset: found,
        target: abs,
        code: res.code,
        exists: existsSync(abs),
        size: existsSync(abs) ? readFileSync(abs).length : -1,
        errors: all.filter((l) => /error|fail|missing/i.test(l)).slice(0, 40),
        output_tail: all.filter((l) => l.trim()).slice(-25),
      });
    },
  );
}

async function runTests(ctx: Ctx, a: Record<string, unknown>): Promise<unknown> {
  const commands: string[][] = [];
  if (Array.isArray(a.test_command) && a.test_command.length) {
    commands.push(a.test_command as string[]);
  } else {
    if (existsSync(path.join(ctx.config.projectRoot, "addons/gut/gut_cmdln.gd"))) {
      commands.push(["-s", "addons/gut/gut_cmdln.gd"]);
    }
    if (existsSync(path.join(ctx.config.projectRoot, "test_runner.gd"))) {
      commands.push(["-s", "test_runner.gd"]);
    }
    if (existsSync(path.join(ctx.config.projectRoot, "tests/test_runner.gd"))) {
      commands.push(["-s", "tests/test_runner.gd"]);
    }
    if (!commands.length) {
      throw new EngineError(
        "Не найден раннер тестов. Ожидается addons/gut/gut_cmdln.gd, test_runner.gd или tests/test_runner.gd. " +
          "Передайте свою команду через test_command.",
        "not_found",
      );
    }
  }
  const results = [];
  for (const cmd of commands) {
    const started = Date.now();
    const res = await ctx.engine.runCli(["--headless", ...cmd], {
      timeout: Number(a.timeout_ms ?? ctx.config.cliTimeoutMs),
    });
    const lines = `${res.stdout}\n${res.stderr}`.split("\n");
    const pass = lines.filter((l: string) => /\bpassed\b|Tests? passed|OK\b/i.test(l)).length;
    const fail = lines.filter((l: string) => /\bfailed\b|FAILED|assert/i.test(l));
    results.push({
      command: cmd.join(" "),
      code: res.code,
      duration_ms: Date.now() - started,
      pass_lines: pass,
      failures: fail.slice(0, 40),
      output_tail: lines.filter((l) => l.trim()).slice(-40),
    });
  }
  return { runs: results, ok: results.every((r) => r.code === 0 && r.failures.length === 0) };
}

export function registerBackupTools(register: Register): void {
  register(
    "godot_scene_backups",
    {
      title: "Бэкапы сцен",
      readOnly: true,
      description: "Список автоматических бэкапов сцен из .mcp-backups (создаются перед каждой записью сцены).",
      shape: {
        file: z.string().optional().describe("Имя файла сцены для фильтра, например main.tscn"),
        limit: z.number().int().min(1).max(200).optional(),
      },
    },
    async (a, ctx) => text(await ctx.engine.call("scene.backups", a as Record<string, unknown>)),
  );
}

function readMainScene(root: string): string {
  try {
    const text = readFileSync(path.join(root, "project.godot"), "utf8");
    const m = /run\/main_scene\s*=\s*"([^"]+)"/.exec(text);
    return m?.[1] ?? "";
  } catch {
    return "";
  }
}

function exportTemplatesDir(versionFull: string): string {
  const tag = versionFull.split(".").slice(0, 3).join(".");
  const status = /\.([a-z0-9]+)\./i.exec(versionFull)?.[1] ?? "stable";
  const cache = process.env.XDG_DATA_HOME ?? path.join(process.env.HOME ?? "", ".local", "share");
  return path.join(cache, "godot", "export_templates", `${tag}.${status}`);
}
