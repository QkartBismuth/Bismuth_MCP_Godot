import path from "node:path";
import { z } from "zod";
import { ensureInsideProject, text, textWithImage, variantNote, type Ctx, type Register } from "../mcp/helpers.js";
import { EngineError } from "../engine/godot.js";
import { groupTracebacks } from "../engine/logs.js";

export function registerRuntimeTools(register: Register): void {
  register(
    "godot_run",
    {
      title: "Запуск игры",
      description:
        "Управление запущенной игрой внутри headless-хоста Godot. mode=start — загрузить сцену в дерево (по умолчанию main_scene), " +
        "mode=stop — выгрузить, mode=status — состояние, mode=step — выполнить N кадров (или seconds) с автоматической паузой " +
        "после (удобно для пошаговой отладки), mode=configure — пауза, time_scale, max_fps. " +
        "Важно: чтобы увидеть игру, сначала вызовите mode=start с render=true, затем godot_screenshot.",
      shape: {
        mode: z.enum(["start", "stop", "status", "step", "configure"]).default("status"),
        scene: z.string().optional().describe("Сцена для запуска (по умолчанию application/run/main_scene)"),
        render: z.boolean().optional().describe("true — запустить с реальным рендерером (нужно для скриншотов, открывает окно)"),
        restart: z.boolean().optional().describe("Перезапустить, если игра уже запущена"),
        frames: z.number().int().min(1).max(100000).optional().describe("Кадров для mode=step"),
        seconds: z.number().min(0.001).max(3600).optional().describe("Альтернатива frames: проиграть секунды"),
        paused: z.boolean().optional(),
        time_scale: z.number().min(0).max(100).optional(),
        max_fps: z.number().int().min(0).max(1000).optional(),
        fixed_fps: z.number().int().min(1).max(1000).optional(),
        timeout_ms: z.number().int().min(1000).max(600000).optional(),
      },
    },
    async (a, ctx) => {
      const mode = String(a.mode);
      switch (mode) {
        case "start": {
          const res = await ctx.engine.call<Record<string, unknown>>(
            "runtime.start",
            {
              scene: a.scene,
              restart: a.restart ?? false,
              max_fps: a.max_fps,
              time_scale: a.time_scale,
              fixed_fps: a.fixed_fps,
            },
            { ensureRender: a.render, timeoutMs: a.timeout_ms },
          );
          if (a.render) {
            // Даём кадру отрисоваться, чтобы первый скриншот не был пустым.
            await stepFrames(ctx, 2);
          }
          return text(res);
        }
        case "stop":
          return text(await ctx.engine.call("runtime.stop", {}));
        case "status":
          return text({ runtime: ctx.engine.getState(), status: await ctx.engine.call("runtime.status", {}).catch((e) => ({ error: (e as Error).message })) });
        case "configure":
          return text(await ctx.engine.call("runtime.pause", { paused: a.paused, time_scale: a.time_scale, max_fps: a.max_fps }));
        default: {
          const frames = a.frames ?? (a.seconds ? Math.max(1, Math.round(a.seconds * 60)) : 1);
          const done = ctx.engine.waitForEvent("step_complete", () => true, a.timeout_ms ?? ctx.config.stepTimeoutMs);
          await ctx.engine.call("runtime.step", { frames }, { timeoutMs: ctx.config.stepTimeoutMs });
          const result = await done;
          return text(result);
        }
      }
    },
  );

  register(
    "godot_runtime",
    {
      title: "Инспекция и управление рантаймом",
      description:
        "Работа с живой игрой. mode=tree — дерево узлов, mode=inspect — свойства узла, mode=find — поиск по имени/типу/группе/скрипту, " +
        "mode=get / set — чтение и запись свойств (в том числе вложенных вида \"theme/colors/font_color\"), " +
        "mode=call — вызов метода узла, mode=emit — отправка сигнала, mode=connect — соединение сигнала с методом. " +
        `Сначала запустите игру через godot_run { mode: \"start\" }. ${variantNote}`,
      shape: {
        mode: z.enum(["tree", "inspect", "find", "get", "set", "call", "emit", "connect"]).default("tree"),
        node: z.string().optional().describe("Путь к узлу, например Player/Sprite2D"),
        root: z.string().optional().describe("Поддерево для mode=tree (по умолчанию корень сцены)"),
        props: z.enum(["none", "saved", "all", "custom"]).optional(),
        prop_names: z.array(z.string()).optional(),
        prop_limit: z.number().int().min(1).max(200).optional(),
        max_depth: z.number().int().min(0).max(64).optional(),
        max_nodes: z.number().int().min(1).max(5000).optional(),
        property_mode: z.enum(["saved", "all", "custom"]).optional(),
        method_filter: z.string().optional(),
        limit: z.number().int().min(1).max(2000).optional(),
        name: z.string().optional().describe("Подстрока имени узла для mode=find"),
        type: z.string().optional().describe("Тип узла для mode=find (с учётом наследования)"),
        group: z.string().optional().describe("Группа для mode=find"),
        script: z.string().optional().describe("Путь к скрипту для mode=find"),
        has_script: z.boolean().optional(),
        property: z.string().optional().describe("Имя свойства для mode=get"),
        items: z.array(z.object({ key: z.string(), value: z.unknown() }).passthrough()).optional(),
        value: z.unknown().optional(),
        method: z.string().optional().describe("Метод для mode=call"),
        args: z.array(z.unknown()).optional().describe("Аргументы вызова"),
        signal: z.string().optional(),
        from: z.string().optional().describe("Исходный узел для mode=connect"),
        to: z.string().optional().describe("Целевой узел для mode=connect"),
        disconnect: z.boolean().optional(),
      },
    },
    async (a, ctx) => {
      const mode = String(a.mode);
      const base = {} as const;
      switch (mode) {
        case "tree":
          return text(
            await ctx.engine.call(
              "runtime.tree",
              {
                node: a.root ?? "",
                props: a.props ?? "none",
                prop_names: a.prop_names ?? [],
                prop_limit: a.prop_limit ?? 24,
                max_depth: a.max_depth ?? 0,
                max_nodes: a.max_nodes ?? 400,
              },
              base,
            ),
          );
        case "inspect":
          return text(
            await ctx.engine.call(
              "runtime.inspect",
              {
                node: a.node,
                mode: a.property_mode ?? "saved",
                props: [],
                method_filter: a.method_filter ?? "",
                limit: a.limit ?? 200,
              },
              base,
            ),
          );
        case "find":
          return text(
            await ctx.engine.call(
              "runtime.find",
              {
                name: a.name,
                type: a.type,
                group: a.group,
                script: a.script,
                has_script: a.has_script,
                limit: a.limit ?? 50,
              },
              base,
            ),
          );
        case "get":
          return text(await ctx.engine.call("runtime.get", { node: a.node, property: a.property }, base));
        case "set": {
          const items = a.items ?? [{ key: String(a.property ?? ""), value: a.value }];
          return text(await ctx.engine.call("runtime.set", { node: a.node, items }, base));
        }
        case "call":
          return text(
            await ctx.engine.call(
              "runtime.call",
              { node: a.node, method: a.method, args: a.args ?? [] },
              base,
            ),
          );
        case "emit":
          return text(
            await ctx.engine.call("runtime.emit", { node: a.node, signal: a.signal, args: a.args ?? [] }, base),
          );
        default:
          return text(
            await ctx.engine.call(
              "runtime.connect",
              { from: a.from, to: a.to, signal: a.signal, method: a.method, disconnect: a.disconnect },
              base,
            ),
          );
      }
    },
  );

  register(
    "godot_input",
    {
      title: "Ввод в игру",
      description:
        "Инъекция ввода в запущенную игру без участии ОС (работает и в headless). mode=action — нажать/отпустить действие InputMap " +
        "(move_left, jump...), mode=key — клавиша по имени (\"SPACE\", \"A\", \"ESCAPE\"), mode=mouse_button, mode=mouse_motion, " +
        "mode=joy_button, mode=release_all — отпустить всё. После нажатия имеет смысл выполнить godot_run { mode: \"step\" }.",
      shape: {
        mode: z.enum(["action", "key", "mouse_button", "mouse_motion", "joy_button", "release_all"]).default("action"),
        action: z.string().optional(),
        key: z.string().optional().describe("Имя клавиши Godot: SPACE, A, ESCAPE, F1..."),
        button: z.number().int().optional().describe("Индекс кнопки мыши (1=левая) или джойстика (0=A)"),
        pressed: z.boolean().optional(),
        strength: z.number().min(0).max(1).optional(),
        position: z.object({ x: z.number(), y: z.number() }).optional(),
        relative: z.object({ x: z.number(), y: z.number() }).optional(),
        shift: z.boolean().optional(),
        ctrl: z.boolean().optional(),
        alt: z.boolean().optional(),
        meta: z.boolean().optional(),
        unicode: z.number().int().optional().describe("Unicode-код символа для mode=text"),
      },
    },
    async (a, ctx) => text(await ctx.engine.call("runtime.input", a as Record<string, unknown>)),
  );

  register(
    "godot_screenshot",
    {
      title: "Скриншот игры",
      description:
        "Снимок кадра игры в PNG. Требует запуска с render=true (godot_run { mode: \"start\", render: true }) — в headless " +
        "рендерера нет. node — вырезать область узла (Control/Node2D/Node3D). Возвращает путь к файлу и само изображение.",
      shape: {
        path: z.string().optional().describe("Путь для сохранения, по умолчанию .mcp-shots/shot_<ts>.png"),
        node: z.string().optional().describe("Узел для кропа кадра"),
        scale: z.number().min(0.05).max(4).optional().describe("Масштаб PNG после захвата"),
        timeout_ms: z.number().int().min(1000).max(120000).optional(),
      },
    },
    async (a, ctx) => {
      const state = ctx.engine.getState();
      if (state.display === "headless") {
        throw new EngineError(
          "Скриншоты требуют рендера. Запустите игру так: godot_run { mode: \"start\", render: true }.",
          "no_renderer",
          `В конфиге сервера GODOT_MCP_RENDER=1 сделает рендер режимом по умолчанию (драйвер: ${ctx.config.renderDisplayDriver}/${ctx.config.renderRenderingDriver}).`,
        );
      }
      const res = await ctx.engine.call<{ path: string; real_path: string }>(
        "capture.screenshot",
        { path: a.path, node: a.node, scale: a.scale },
        { ensureRender: true, timeoutMs: a.timeout_ms ?? 30_000 },
      );
      const abs = path.isAbsolute(String(res.path)) ? String(res.path) : ensureInsideProject(ctx, String(res.path));
      return textWithImage(res, abs);
    },
  );

  register(
    "godot_logs",
    {
      title: "Логи и ошибки",
      readOnly: true,
      description:
        "Вывод запущенного Godot: print из игры, ошибки и трассировки. mode=tail — последние строки, mode=errors — только ошибки " +
        "и предупреждения с разобранными стек-трейсами, mode=clear — сбросить буфер. Используйте cursor из ответа для " +
        "инкрементального чтения (since).",
      shape: {
        mode: z.enum(["tail", "errors", "clear"]).default("tail"),
        limit: z.number().int().min(1).max(4000).optional(),
        since: z.number().int().min(0).optional().describe("Читать начиная с seq предыдущего ответа"),
        level: z.enum(["debug", "info", "warning", "error", "success"]).optional(),
        grep: z.string().optional().describe("Фильтр по подстроке"),
      },
    },
    async (a, ctx) => {
      if (a.mode === "clear") {
        ctx.engine.logs.clear();
        return text({ cleared: true });
      }
      const listed = ctx.engine.logs.list({
        limit: a.limit ?? 200,
        since: a.since,
        level: a.level,
        errorsOnly: a.mode === "errors",
      });
      const entries = a.grep
        ? listed.entries.filter((e) => e.text.includes(String(a.grep)))
        : listed.entries;
      return text({
        mode: a.mode,
        cursor: listed.cursor,
        truncated: listed.truncated,
        count: entries.length,
        lines: entries.map((e) => `[${e.level}] ${e.text}`),
        tracebacks: a.mode === "errors" ? groupTracebacks(entries) : undefined,
      });
    },
  );

  register(
    "godot_image",
    {
      title: "Изображение ассета",
      readOnly: true,
      description:
        "Возвращает текстуру проекта как PNG-блок (визуальная проверка спрайтов, иконок, атласов) и краткую информацию " +
        "о размере/формате. size — привести к квадрату указанного размера (0 = без изменений).",
      shape: {
        path: z.string().describe("Путь к текстуре: res://icon.svg, res://art/hero.png"),
        size: z.number().int().min(0).max(2048).optional(),
        out: z.string().optional().describe("Куда сохранить PNG (по умолчанию .mcp-shots)"),
      },
    },
    async (a, ctx) => {
      const res = await ctx.engine.call<{ path: string; real_path: string; image: unknown }>("capture.resource_image", {
        path: a.path,
        size: a.size ?? 0,
        out: a.out,
      });
      return textWithImage(res, res.real_path);
    },
  );
}

async function stepFrames(ctx: Ctx, frames: number): Promise<void> {
  try {
    const done = ctx.engine.waitForEvent("step_complete", () => true, 20_000);
    await ctx.engine.call("runtime.step", { frames });
    await done;
  } catch {
    /* шаг не критичен для ответа */
  }
}