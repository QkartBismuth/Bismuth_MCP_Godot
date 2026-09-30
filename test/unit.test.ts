import { describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { findProjectRoot, loadConfig, safeJoin, toResPath } from "../src/config.js";
import { LogBuffer, groupTracebacks, parseFrame } from "../src/engine/logs.js";
import { ApiIndex } from "../src/engine/apiIndex.js";
import { parseVersion } from "../src/engine/godot.js";

function withProject(fn: (dir: string) => void | Promise<void>): void | Promise<void> {
  const dir = mkdtempSync(path.join(tmpdir(), "bismuth-mcp-godot-unit-"));
  const done = fn(dir);
  if (done instanceof Promise) return done.finally(() => rmSync(dir, { recursive: true, force: true }));
  rmSync(dir, { recursive: true, force: true });
  return done;
}

describe("config", () => {
  it("находит корень проекта вверх по дереву", () => {
    withProject((dir) => {
      mkdirSync(path.join(dir, "a", "b", "c"), { recursive: true });
      writeFileSync(path.join(dir, "project.godot"), "config_version=5\n");
      expect(findProjectRoot(path.join(dir, "a", "b", "c"))).toBe(dir);
    });
  });

  it("падает с понятной ошибкой, если project.godot не найден", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "bismuth-mcp-godot-empty-"));
    try {
      expect(() => findProjectRoot(dir)).toThrow(/project\.godot/);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("читает настройки из окружения", () => {
    withProject((dir) => {
      writeFileSync(path.join(dir, "project.godot"), "config_version=5\n");
      process.env.GODOT_PROJECT = dir;
      process.env.GODOT_BIN = "/opt/godot";
      process.env.GODOT_MCP_RENDER = "1";
      try {
        const cfg = loadConfig("/");
        expect(cfg.projectRoot).toBe(dir);
        expect(cfg.godotBin).toBe("/opt/godot");
        expect(cfg.render).toBe(true);
        expect(cfg.cacheDir).toContain("bismuth-mcp-godot");
      } finally {
        delete process.env.GODOT_PROJECT;
        delete process.env.GODOT_BIN;
        delete process.env.GODOT_MCP_RENDER;
      }
    });
  });

  it("не выпускает пути за пределы проекта", () => {
    withProject((dir) => {
      expect(toResPath(dir, "scenes/main.tscn")).toBe("res://scenes/main.tscn");
      expect(toResPath(dir, "res://scenes/main.tscn")).toBe("res://scenes/main.tscn");
      expect(() => safeJoin(dir, "../../etc/passwd")).toThrow(/выходит за пределы/);
      expect(() => toResPath(dir, "/etc/passwd")).toThrow();
      expect(() => toResPath(dir, "../../etc/passwd")).toThrow();
    });
  });
});

describe("version", () => {
  it("разбирает строку версии Godot", () => {
    const v = parseVersion("4.7.2.stable.arch_linux.ed1daf0bf");
    expect(v).toMatchObject({ major: 4, minor: 7, patch: 2, status: "stable" });
  });
});

describe("логи", () => {
  it("классифицирует уровни и разбирает трассировки", () => {
    const logs = new LogBuffer(100, false);
    logs.push("stdout", "Godot Engine v4.7.2\n");
    logs.push("stdout", "[demo] игрок погиб\n");
    logs.push("stderr", "SCRIPT ERROR: Invalid call. Nonexistent function 'x'.\n");
    logs.push("stderr", "          at: _ready (res://scripts/main.gd:12)\n");
    logs.push("stderr", "          at: _process (res://scripts/player.gd:31)\n");
    logs.flush();
    const { entries } = logs.list({ limit: 10 });
    expect(entries).toHaveLength(5);
    expect(entries.map((e) => e.level)).toEqual(["info", "info", "error", "error", "error"]);
    const tracebacks = groupTracebacks(entries);
    expect(tracebacks).toHaveLength(1);
    expect(tracebacks[0]?.frames).toHaveLength(2);
    expect(tracebacks[0]?.frames[0]?.line).toBe(12);
  });

  it("разбирает отдельный кадр стека", () => {
    expect(parseFrame("   at: do_it (res://a/b.gd:42)")).toEqual({ func: "do_it", file: "res://a/b.gd", line: 42 });
    expect(parseFrame("не кадр")).toBeUndefined();
  });

  it("поддерживает курсор и фильтр по уровню", () => {
    const logs = new LogBuffer(1000, false);
    for (let i = 0; i < 10; i += 1) logs.push("stdout", `строка ${i}\n`);
    logs.flush();
    const first = logs.list({ limit: 5 });
    expect(first.entries).toHaveLength(5);
    expect(first.entries[0]?.text).toBe("строка 5");
    const next = logs.list({ limit: 5, since: first.cursor });
    expect(next.entries).toHaveLength(0);
  });

  it("ограничивает размер кольцевого буфера", () => {
    const logs = new LogBuffer(10, false);
    for (let i = 0; i < 50; i += 1) logs.push("stdout", `s${i}\n`);
    logs.flush();
    const { entries } = logs.list({ limit: 100 });
    expect(entries).toHaveLength(10);
    expect(entries[0]?.text).toBe("s40");
  });
});

describe("индекс API", () => {
  it("читает кэш extension_api.json и строит карту классов", async () => {
    await withProject(async (dir) => {
      const cacheFile = path.join(dir, "extension_api.json");
      const fake = {
        classes: [
          {
            name: "TestNode",
            inherits: "Node",
            brief: "Тестовый узел.",
            description: "Длинное описание.",
            methods: [
              { name: "do_it", is_static: false, brief: "Делает дело.", arguments: [{ name: "x", type: "int" }], return_value: { type: "void" } },
            ],
            properties: [{ name: "speed", type: "float", brief: "Скорость.", default_value: "100.0" }],
            signals: [{ name: "fired", arguments: [] }],
            enums: [{ name: "Mode", is_bitfield: false, values: [{ name: "MODE_OFF", value: 0 }, { name: "MODE_ON", value: 1 }] }],
            constants: [{ name: "MAX", value: 10, brief: "Максимум." }],
          },
          { name: "Node", methods: [{ name: "get_name" }], properties: [], signals: [], enums: [], constants: [] },
        ],
      };
      writeFileSync(cacheFile, JSON.stringify(fake));
      const version = parseVersion("4.7.2.stable");
      const api = new ApiIndex(dir, async () => ({ code: 0, stdout: "", stderr: "" }));
      // Подменяем путь кэша на подготовленный файл.
      Object.defineProperty(api, "cacheFile", { value: () => cacheFile });
      const ok = await api.ensure(version);
      expect(ok).toBe(true);
      expect(api.isLoaded()).toBe(true);
      const doc = api.describe("TestNode");
      expect(doc?.inherits).toBe("Node");
      expect(doc?.methods.do_it?.args).toEqual(["int x"]);
      // Методы родителя видны при describe(include_inherited=true)
      expect(doc?.methods.get_name).toBeTruthy();
      const own = api.describe("TestNode", false);
      expect(own?.methods.get_name).toBeUndefined();
      const found = api.search("do_it");
      expect(found.results.some((r) => r.name === "do_it")).toBe(true);
      expect(api.search("MODE_ON").results.some((r) => r.kind === "enum_value")).toBe(true);
      expect(api.getMeta()?.classes).toBe(2);
    });
  });
});
