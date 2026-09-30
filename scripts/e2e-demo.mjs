#!/usr/bin/env node
// Демонстрация полного цикла агента: создание сцены, проверка скриптов, запуск игры,
// покадровая отладка, скриншот и чтение состояния. Запуск: node scripts/e2e-demo.mjs
import { loadConfig } from "../dist/config.js";
import { createCtx } from "../dist/mcp/helpers.js";
import { createServer } from "../dist/mcp/server.js";
import { Client } from "../node_modules/@modelcontextprotocol/sdk/dist/esm/client/index.js";
import { InMemoryTransport } from "../node_modules/@modelcontextprotocol/sdk/dist/esm/inMemory.js";
import { mkdtempSync, readFileSync, existsSync, cpSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

// Сценарий «агент с нуля»: создать проект, собрать сцену, запустить, снять кадр.
const root = mkdtempSync(path.join(tmpdir(), "e2e-"));
cpSync(new URL("../test/fixtures/demo-project", import.meta.url).pathname, root, { recursive: true });
rmSync(path.join(root, ".godot"), { recursive: true, force: true });
process.env.GODOT_PROJECT = root;
const ctx = createCtx(loadConfig(root));
const server = createServer(ctx);
const [ct, st] = InMemoryTransport.createLinkedPair();
const client = new Client({ name: "e2e", version: "1" });
await Promise.all([server.connect(st), client.connect(ct)]);
const call = async (name, args = {}) => {
  const res = await client.callTool({ name, arguments: args });
  const raw = res.content?.[0]?.text ?? "";
  let d; try { d = JSON.parse(raw); } catch { d = raw.slice(0, 200); }
  if (res.isError) { console.log(`✘ ${name}: ${raw.slice(0, 200)}`); throw new Error(name); }
  console.log(`✔ ${name}`);
  return d;
};
try {
  const edit = await call("godot_scene", { mode: "create", path: "res://scenes/level.tscn", root_type: "Node2D", root_name: "Level", overwrite: true, ops: [
    { op: "add_node", parent: ".", type: "ColorRect", name: "Backdrop", props: { size: { $: "Vector2", x: 1152, y: 648 }, color: { $: "Color", hex: "#1b2030" } } },
    { op: "add_node", parent: ".", type: "CharacterBody2D", name: "Player", script: "res://scripts/player.gd", props: { position: { $: "Vector2", x: 120, y: 60 } } },
    { op: "add_node", parent: "Player", type: "CollisionShape2D", name: "Body", props: { shape: { $: "ClassRef", class: "CapsuleShape2D" } } },
    { op: "add_node", parent: ".", type: "Marker2D", name: "Spawn" },
    { op: "remove_node", path: "Spawn" },
    { op: "set_props", path: ".", props: { script: { path: "res://scripts/main.gd" } } },
  ] });
  console.log("   операции:", (edit.ops ?? []).map((o) => `${o.op}:${o.status}`).join(", "), "| ключи:", Object.keys(edit).join(","));
  console.log("   level.tscn:\n" + readFileSync(path.join(root, "scenes/level.tscn"), "utf8").split("\n").map((l) => "     " + l).join("\n"));
  const setMain = await call("godot_project_settings", { mode: "set", items: [{ key: "application/run/main_scene", value: "res://scenes/level.tscn" }], save: true });
  console.log("   main_scene:", JSON.stringify(setMain.applied));
  const chk = await call("godot_script_check", { dir: "res://scripts" });
  console.log("   ошибок компиляции:", chk.error_count);
  const run = await call("godot_run", { mode: "start", render: true, scene: "res://scenes/level.tscn" });
  console.log("   рантайм:", run.status, "root:", run.root);
  const step = await call("godot_run", { mode: "step", frames: 60 });
  console.log("   кадров:", step.frames, "пауза:", step.status.paused);
  const shot = await call("godot_screenshot", { path: "res://.mcp-shots/e2e.png", node: "Backdrop" });
  console.log("   скриншот:", shot.real_path, JSON.stringify(shot.size));
  const logs = await call("godot_logs", { mode: "tail", limit: 5 });
  console.log("   логи игры:", logs.lines.filter((l) => l.includes("[e2e]")).join(" / ") || "(нет строк [e2e])");
  await call("godot_runtime", { mode: "get", node: "Player", property: "position" });
  const pos = await call("godot_runtime", { mode: "get", node: "Player", property: "position" });
  console.log("   позиция игрока:", JSON.stringify(pos.value));
  console.log("PNG существует:", existsSync(path.join(root, ".mcp-shots/e2e.png")));
} catch (e) { console.log("СБОЙ СЦЕНАРИЯ:", e.message); }
finally { await ctx.engine.dispose(); }
