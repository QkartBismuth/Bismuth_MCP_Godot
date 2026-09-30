#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, rmSync, statSync } from "node:fs";
import path from "node:path";
import { loadConfig } from "./config.js";
import { createCtx } from "./mcp/helpers.js";
import { PACKAGE_ROOT, HOST_TARGET } from "./engine/godot.js";
import { defaultLspPort } from "./engine/editor.js";
import { createConnection } from "node:net";

/**
 * Диагностика окружения: Bismuth_MCP_Godot doctor
 * Проверяет бинарь Godot, проект, хост, скриншоты, LSP, редакторный мост и кэш API.
 */
const OK = "✔";
const WARN = "!";
const BAD = "✘";
let warnings = 0;
let failures = 0;

function line(mark: string, name: string, detail = ""): void {
  process.stdout.write(`${mark} ${name}${detail ? `: ${detail}` : ""}\n`);
}

function warn(name: string, detail: string): void {
  warnings += 1;
  line(WARN, name, detail);
}

function bad(name: string, detail: string): void {
  failures += 1;
  line(BAD, name, detail);
}

async function portOpen(port: number, timeoutMs = 600): Promise<boolean> {
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

async function main(): Promise<void> {
  const clean = process.argv.includes("--clean");
  process.stdout.write(clean ? "bismuth-mcp-godot doctor --clean\n\n" : "bismuth-mcp-godot doctor\n\n");
  let config;
  try {
    config = loadConfig();
  } catch (err) {
    bad("Проект Godot", (err as Error).message);
    process.exit(1);
  }
  if (clean) {
    const ctx0 = createCtx(config);
    ctx0.engine.removeHostScripts();
    for (const dir of [".mcp-backups", ".mcp-shots"]) {
      rmSync(path.join(config.projectRoot, dir), { recursive: true, force: true });
    }
    line(OK, "Очистка", "удалены .mcp/, .mcp-backups/, .mcp-shots/");
    await ctx0.engine.dispose();
    process.exit(0);
  }
  line(OK, "Корень проекта", config.projectRoot);
  if (existsSync(path.join(config.projectRoot, "project.godot"))) line(OK, "project.godot найден");
  else bad("project.godot", "отсутствует в корне");
  line(OK, "GDScript-шаблоны", path.relative(process.cwd(), path.join(PACKAGE_ROOT, "godot")) || ".");

  const ctx = createCtx(config);
  try {
    const version = ctx.engine.version();
    line(OK, "Бинарь Godot", `${version.full} (${config.godotBin})`);
    if (version.major !== 4) bad("Версия движка", "сервер рассчитан на Godot 4.x");
  } catch (err) {
    bad("Бинарь Godot", (err as Error).message);
    process.exit(1);
  }

  const godotDir = path.join(config.projectRoot, ".godot");
  if (existsSync(godotDir)) line(OK, "Импорт проекта", ".godot на месте");
  else warn("Импорт проекта", ".godot отсутствует — будет выполнен godot --import при первом обращении");

  if (existsSync(path.join(config.projectRoot, HOST_TARGET, "host.gd"))) {
    line(OK, "Скрипты хоста", `${HOST_TARGET}/host.gd установлен`);
  } else {
    warn("Скрипты хоста", "будут скопированы в проект при первом обращении");
  }

  const t0 = Date.now();
  try {
    const info = await ctx.engine.call<{ display: { server: string }; project: { main_scene: string } }>("host.info", {});
    line(OK, "Headless-хост", `за ${Date.now() - t0} мс, display=${info.display.server}`);
    if (info.project.main_scene) line(OK, "Главная сцена", info.project.main_scene);
    else warn("Главная сцена", "application/run/main_scene не задан — godot_run потребует параметр scene");
  } catch (err) {
    bad("Headless-хост", (err as Error).message);
  }

  if (config.render || process.env.DISPLAY || process.env.WAYLAND_DISPLAY) {
    try {
      const res = await ctx.engine.call<{ real_path: string; size: { width: number } }>(
        "capture.screenshot",
        { path: "res://.mcp-shots/doctor.png" },
        { ensureRender: true, timeoutMs: 30_000 },
      );
      const size = statSync(res.real_path).size;
      line(OK, "Скриншоты", `${res.size.width}px, ${size} байт → ${res.real_path}`);
      await ctx.engine.call("runtime.stop", {}).catch(() => undefined);
    } catch (err) {
      warn("Скриншоты", (err as Error).message);
    }
  } else {
    warn("Скриншоты", "нет DISPLAY/WAYLAND_DISPLAY: рендер и скриншоты недоступны");
  }

  if (await portOpen(defaultLspPort())) {
    line(OK, "GDScript LSP", `редактор уже слушает порт ${defaultLspPort()}`);
  } else {
    warn("GDScript LSP", "редактор не запущен; сервер поднимет headless-редактор при первом godot_lsp");
  }

  if (ctx.engine.hasEditorBridge()) {
    line(OK, "Мост редактора", "плагин подключён");
  } else {
    const addon = path.join(config.projectRoot, "addons", "bismuth_mcp_godot", "plugin.cfg");
    if (existsSync(addon)) warn("Мост редактора", "аддон установлен, но редактор не подключился — проверьте, что плагин включён");
    else warn("Мост редактора", "не установлен: godot_editor { mode: \"install_bridge\" }");
  }

  const apiMeta = ctx.api.getMeta();
  const apiFile = apiMeta?.file;
  if (apiFile && existsSync(apiFile)) {
    line(OK, "Индекс документации API", `${apiMeta?.classes} классов, ${(statSync(apiFile).size / 1048576).toFixed(1)} МБ`);
  } else {
    warn("Индекс документации API", "не собран: godot_class { mode: \"build_api_index\" } (собирается из --dump-extension-api-with-docs, ~6 c)");
  }

  const serverCfg = path.join(config.projectRoot, ".mcp", "version.json");
  if (existsSync(serverCfg)) {
    try {
      const v = JSON.parse(readFileSync(serverCfg, "utf8")) as { protocol: number };
      if (v.protocol === 1) line(OK, "Протокол хоста", "v1");
      else bad("Протокол хоста", `ожидается 1, в проекте ${v.protocol}`);
    } catch {
      warn("Протокол хоста", "не удалось прочитать version.json");
    }
  }

  // Каталог скриншотов/бэкапов внутри проекта — напоминание, что их стоит игнорировать в VCS.
  const gitignore = path.join(config.projectRoot, ".gitignore");
  if (existsSync(gitignore)) {
    const text = readFileSync(gitignore, "utf8");
    if (text.includes(".mcp")) line(OK, ".gitignore", "служебные каталоги исключены");
    else warn(".gitignore", "добавьте .mcp/, .mcp-backups/, .mcp-shots/");
  } else {
    warn(".gitignore", "файла нет — служебные каталоги MCP попадут в репозиторий");
  }

  mkdirSync(path.join(config.projectRoot, ".mcp-shots"), { recursive: true });
  process.stdout.write(`\nИтог: ${failures ? `${failures} ошибок, ` : ""}${warnings} предупреждений\n`);
  await ctx.engine.dispose();
  process.exit(failures > 0 ? 1 : 0);
}

main().catch((err) => {
  process.stderr.write(`doctor: ${err instanceof Error ? (err.stack ?? err.message) : String(err)}\n`);
  process.exit(1);
});
