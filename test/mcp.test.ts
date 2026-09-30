import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";
import { loadConfig } from "../src/config.js";
import { createCtx, type Ctx } from "../src/mcp/helpers.js";
import { createServer } from "../src/mcp/server.js";
import { makeProject } from "./helpers.js";
import { rmSync } from "node:fs";

/**
 * Проверка уровня MCP: клиент SDK видит все инструменты, схемы валидны,
 * а типичный вызов возвращает осмысленный JSON.
 */
describe("MCP-сервер", () => {
  let dir: string;
  let ctx: Ctx;
  let client: Client;

  beforeAll(async () => {
    dir = makeProject();
    process.env.GODOT_PROJECT = dir;
    const cfg = loadConfig(dir);
    ctx = createCtx(cfg);
    const server = createServer(ctx);
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    client = new Client({ name: "test", version: "1.0.0" });
    await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  }, 120_000);

  afterAll(async () => {
    await ctx?.engine.dispose();
    delete process.env.GODOT_PROJECT;
    if (dir) rmSync(dir, { recursive: true, force: true });
  });

  it("регистрирует все заявленные инструменты с описаниями", async () => {
    const { tools } = await client.listTools();
    const names = tools.map((t) => t.name).sort();
    const expected = [
      "godot_assets",
      "godot_class",
      "godot_editor",
      "godot_export",
      "godot_files",
      "godot_image",
      "godot_input",
      "godot_logs",
      "godot_lsp",
      "godot_project_import",
      "godot_project_info",
      "godot_project_scaffold",
      "godot_project_settings",
      "godot_resource",
      "godot_run",
      "godot_runtime",
      "godot_scene",
      "godot_scene_backups",
      "godot_scene_edit",
      "godot_script",
      "godot_script_check",
      "godot_screenshot",
      "godot_status",
    ].sort();
    expect(names).toEqual(expected);
    for (const tool of tools) {
      expect(tool.description ?? "").not.toBe("");
      expect(tool.inputSchema).toBeTruthy();
    }
  });

  it("godot_status отдаёт состояние окружения", async () => {
    const res = (await client.callTool({ name: "godot_status", arguments: {} })) as any;
    const text = res.content.find((c: any) => c.type === "text")?.text ?? "";
    const data = JSON.parse(text);
    expect(data.ok).toBe(true);
    expect(data.engine.major).toBeGreaterThanOrEqual(4);
    expect(data.project.root).toContain("bismuth-mcp-godot-test-");
  });

  it("godot_scene возвращает дерево сцены", async () => {
    const res = (await client.callTool({
      name: "godot_scene",
      arguments: { mode: "state", path: "res://scenes/main.tscn" },
    })) as any;
    const data = JSON.parse(res.content[0].text);
    expect(data.nodes.map((n: any) => n.name)).toContain("Player");
  });

  it("godot_scene_edit поддерживает dry run", async () => {
    const res = (await client.callTool({
      name: "godot_scene_edit",
      arguments: {
        path: "res://scenes/hud.tscn",
        ops: [{ op: "add_node", type: "Label", name: "Score", props: { text: "0" } }],
      },
    })) as any;
    const raw = res.content[0].text as string;
    if (res.isError) throw new Error(`godot_scene_edit вернул ошибку: ${raw}`);
    const data = JSON.parse(raw);
    expect(data.dry_run).toBe(true);
    expect(data.ops[0].status).toBe("ok");
  });

  it("сообщает об ошибке понятным текстом, а не исключением", async () => {
    const res = (await client.callTool({
      name: "godot_scene",
      arguments: { mode: "state", path: "res://нет-такой.tscn" },
    })) as any;
    expect(res.isError).toBe(true);
    const text = res.content[0].text as string;
    expect(text).toContain("not_found");
    expect(text).toContain("Сцена не найдена");
  });

  it("не выпускает за пределы корня проекта", async () => {
    const res = (await client.callTool({
      name: "godot_files",
      arguments: { mode: "read", path: "../../../etc/passwd" },
    })) as any;
    expect(res.isError).toBe(true);
    expect(res.content[0].text as string).toContain("sandbox");
  });

  it("godot_class отдаёт структуру класса", async () => {
    const res = (await client.callTool({
      name: "godot_class",
      arguments: { mode: "info", class: "Node2D", sections: ["signals"] },
    })) as any;
    const data = JSON.parse(res.content[0].text);
    expect(data.class).toBe("Node2D");
    expect(data.signals.map((s: any) => s.name)).toContain("ready");
  });
});
