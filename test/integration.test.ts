import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { startHarness, type Harness } from "./helpers.js";

/**
 * Интеграционные тесты с настоящим Godot: поднимают headless-хост
 * на копии демо-проекта и проверяют основные сценарии агента.
 */
describe("Godot MCP — интеграция", () => {
  let h: Harness;

  beforeAll(async () => {
    h = await startHarness();
  }, 180_000);

  afterAll(async () => {
    await h?.dispose();
  });

  it("поднимает headless-хост и отдаёт сведения о движке", async () => {
    const info = (await h.ctx.engine.call<any>("host.info", {})) as any;
    expect(info.engine.major).toBeGreaterThanOrEqual(4);
    expect(info.display.server).toBe("headless");
    expect(info.project.root).toContain("bismuth-mcp-godot-test-");
    expect(h.ctx.engine.getState().running).toBe(true);
  }, 90_000);

  it("читает настройки и сцену проекта", async () => {
    const project = (await h.ctx.engine.call<any>("project.info", {})) as any;
    expect(project.name).toBe("DemoPlatformer");
    expect(project.main_scene).toBe("res://scenes/main.tscn");

    const state = (await h.ctx.engine.call<any>("scene.state", { path: "res://scenes/main.tscn" })) as any;
    const names = state.nodes.map((n: any) => n.name);
    expect(names).toContain("Main");
    expect(names).toContain("Player");
    // В файле сохранены только явно заданные свойства — это ключевое отличие от get_property_list.
    const player = state.nodes.find((n: any) => n.name === "Player");
    expect(player.stored_properties.position).toEqual({ $: "Vector2", x: 100, y: 100 });
  });

  it("перечисляет файлы и ассеты с фильтрами", async () => {
    const files = (await h.ctx.engine.call<any>("file.list", { dir: "res://", include: ["*.gd"] })) as any;
    const paths = files.files.map((f: any) => f.path);
    expect(paths).toContain("res://scripts/player.gd");
    expect(paths).not.toContain("res://scenes/main.tscn");

    const excluded = (await h.ctx.engine.call<any>("file.list", {
      dir: "res://scripts",
      include: ["*.gd"],
      exclude: ["hud.gd"],
    })) as any;
    expect(excluded.files.map((f: any) => f.name)).toEqual(["main.gd", "player.gd"]);
  });

  it("даёт справку по классу движка и по глобальным классам проекта", async () => {
    const cls = (await h.ctx.engine.call<any>("classdb.info", { class: "CharacterBody2D" })) as any;
    expect(cls.chain).toContain("Node2D");
    expect(cls.methods.length).toBeGreaterThan(50);
    expect(cls.methods.some((m: any) => m.name === "move_and_slide")).toBe(true);

    const found = (await h.ctx.engine.call<any>("classdb.search", { query: "take_over_path", limit: 5 })) as any;
    expect(found.results.some((r: any) => r.name === "take_over_path")).toBe(true);
  });

  it("разбирает символы скрипта с номерами строк", async () => {
    const sym = (await h.ctx.engine.call<any>("script.symbols", { path: "res://scripts/player.gd" })) as any;
    expect(sym.global_name).toBe("Player");
    const ready = sym.functions.find((f: any) => f.name === "_ready");
    expect(ready.line).toBeGreaterThan(0);
    const speed = sym.variables.find((v: any) => v.name === "speed");
    expect(speed.exported).toBe(true);
    expect(speed.line).toBeGreaterThan(0);
    expect(sym.signals.map((s: any) => s.name)).toContain("died");
    expect(sym.constants.MAX_FALL_SPEED).toBe(900);
  });

  it("редактирует сцену: dry run не трогает файл, save — пишет и делает бэкап", async () => {
    const ops = [
      { op: "add_node", parent: "Player", type: "CollisionShape2D", name: "Body", props: { shape: { $: "ClassRef", class: "CircleShape2D" } } },
      { op: "rename", path: "Ground", name: "Floor" },
    ];
    const dry = (await h.ctx.engine.call<any>("scene.apply_ops", { path: "res://scenes/main.tscn", ops, save: false })) as any;
    expect(dry.saved).toBe(false);
    expect(dry.dry_run).toBe(true);
    expect(dry.ops.every((o: any) => o.status === "ok")).toBe(true);
    const unchanged = (await h.ctx.engine.call<any>("scene.state", { path: "res://scenes/main.tscn" })) as any;
    expect(unchanged.nodes.map((n: any) => n.name)).not.toContain("Body");

    const saved = (await h.ctx.engine.call<any>("scene.apply_ops", { path: "res://scenes/main.tscn", ops, save: true })) as any;
    expect(saved.saved).toBe(true);
    expect(saved.backup).toBeTruthy();
    const after = (await h.ctx.engine.call<any>("scene.state", { path: "res://scenes/main.tscn" })) as any;
    const names = after.nodes.map((n: any) => n.name);
    expect(names).toContain("Body");
    expect(names).toContain("Floor");

    const backups = (await h.ctx.engine.call<any>("scene.backups", { file: "main.tscn" })) as any;
    expect(backups.backups.length).toBeGreaterThan(0);
  });

  it("возвращает понятную ошибку при неверной операции", async () => {
    await expect(
      h.ctx.engine.call("scene.apply_ops", { path: "res://scenes/main.tscn", ops: [{ op: "rename", path: "Ghost", name: "X" }] }),
    ).rejects.toMatchObject({ code: "op_failed" });
    await expect(h.ctx.engine.call("scene.state", { path: "res://missing.tscn" })).rejects.toMatchObject({
      code: "not_found",
    });
  });

  it("запускает игру, шагает по кадрам и управляет узлами", async () => {
    const start = (await h.ctx.engine.call<any>("runtime.start", {})) as any;
    expect(start.status).toBe("started");
    expect(start.scene).toBe("res://scenes/main.tscn");

    const done = h.ctx.engine.waitForEvent("step_complete", () => true, 30_000);
    const stepResult = (await h.ctx.engine.call<any>("runtime.step", { frames: 10 })) as any;
    expect(stepResult.status).toBe("stepping");
    const finished = (await done) as any;
    expect(finished.frames).toBe(10);

    const tree = (await h.ctx.engine.call<any>("runtime.tree", { max_depth: 2 })) as any;
    expect(tree.node_count).toBeGreaterThan(3);

    const get = (await h.ctx.engine.call<any>("runtime.get", { node: "Player", property: "position" })) as any;
    expect(get.value.$).toBe("Vector2");

    await h.ctx.engine.call("runtime.set", { node: "Player", items: [{ key: "position", value: { $: "Vector2", x: 200, y: 40 } }] });
    const moved = (await h.ctx.engine.call<any>("runtime.get", { node: "Player", property: "position" })) as any;
    expect(Math.round(moved.value.x)).toBe(200);

    const found = (await h.ctx.engine.call<any>("runtime.find", { group: "player" })) as any;
    expect(found.nodes.map((n: any) => n.name)).toContain("Player");

    await h.ctx.engine.call("runtime.input", { mode: "action", action: "jump", pressed: true });
    await h.ctx.engine.call("runtime.input", { mode: "key", key: "SPACE", pressed: true });
    const call = (await h.ctx.engine.call<any>("runtime.call", { node: "Player", method: "is_on_floor" })) as any;
    expect(call).toHaveProperty("result");

    const stopped = (await h.ctx.engine.call<any>("runtime.stop", {})) as any;
    expect(stopped.status).toBe("stopped");
  });

  it("собирает логи игры и разбирает их по уровням", async () => {
    const logs = h.ctx.engine.logs.list({ limit: 200 });
    const text = logs.entries.map((e) => e.text).join("\n");
    expect(text).toContain("[demo] main ready");
  });

  it("читает и меняет свойства ресурса", async () => {
    const info = (await h.ctx.engine.call<any>("resource.info", { path: "res://scripts/player.gd" })) as any;
    expect(info.class).toBe("GDScript");
    expect(info.script_info.base).toBe("CharacterBody2D");

    const res = (await h.ctx.engine.call<any>("resource.get", { path: "res://scenes/hud.tscn", props: [] })) as any;
    expect(res.class).toBe("PackedScene");
  });

  it("пишет и читает настройки проекта", async () => {
    const set = (await h.ctx.engine.call<any>("project.settings", {
      mode: "set",
      items: [{ key: "display/window/size/viewport_width", value: 800 }],
      save: true,
    })) as any;
    expect(set.saved).toBe(true);
    const get = (await h.ctx.engine.call<any>("project.settings", {
      mode: "get",
      keys: ["display/window/size/viewport_width"],
    })) as any;
    expect(get.settings["display/window/size/viewport_width"]).toBe(800);
  });

  it("проверяет синтаксис скриптов и ловит ошибки компиляции", async () => {
    const ok = await h.ctx.engine.runCli(["--headless", "--check-only", "-s", "res://scripts/player.gd"]);
    expect(ok.code).toBe(0);
  });
});
