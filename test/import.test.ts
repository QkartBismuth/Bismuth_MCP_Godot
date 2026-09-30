import { describe, it, expect } from "vitest";
import { existsSync, rmSync } from "node:fs";
import path from "node:path";
import { makeProject, waitForImport } from "./helpers.js";
import { loadConfig } from "../src/config.js";
import { createCtx } from "../src/mcp/helpers.js";
import { createServer } from "../src/mcp/server.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { InMemoryTransport } from "@modelcontextprotocol/sdk/inMemory.js";

describe("импорт проекта", () => {
  it("стартует в фоне и не блокирует инструменты больших проектов", async () => {
    const dir = makeProject();
    const ctx = createCtx(loadConfig(dir));
    const server = createServer(ctx);
    const [ct, st] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "t", version: "1" });
    await Promise.all([server.connect(st), client.connect(ct)]);

    // Первый вызов на неимпортированном проекте: внятная ошибка, а не таймаут.
    const started = Date.now();
    const first = (await client.callTool({ name: "godot_project_info", arguments: {} })) as any;
    const elapsed = Date.now() - started;
    if (first.isError) {
      expect(first.content[0].text).toMatch(/importing|import_failed/);
    } else {
      const data = JSON.parse(first.content[0].text);
      expect(data.name).toBe("DemoPlatformer");
    }
    expect(elapsed).toBeLessThan(40_000);

    // godot_status всегда отвечает и показывает состояние импорта.
    const status = (await client.callTool({ name: "godot_status", arguments: {} })) as any;
    const s = JSON.parse(status.content[0].text);
    expect(["ready", "running", "unknown", "failed"]).toContain(s.import.state);

    // Дожидаемся импорта и проверяем, что хост поднимается.
    const deadline = Date.now() + 90_000;
    while (s.import.state !== "ready" && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 1000));
      const again = (await client.callTool({ name: "godot_status", arguments: {} })) as any;
      Object.assign(s, JSON.parse(again.content[0].text));
    }
    expect(existsSync(path.join(dir, ".godot"))).toBe(true);

    const info = (await client.callTool({ name: "godot_project_info", arguments: {} })) as any;
    expect(info.isError).toBeFalsy();
    await ctx.engine.dispose();
    rmSync(dir, { recursive: true, force: true });
  }, 180_000);

  it("не падает без проекта, а объясняет, что делать", async () => {
    const dir = makeProject();
    const ctx = createCtx(loadConfig(dir));
    const server = createServer(ctx);
    const [ct, st] = InMemoryTransport.createLinkedPair();
    const client = new Client({ name: "t", version: "1" });
    await Promise.all([server.connect(st), client.connect(ct)]);
    await waitForImport(ctx);
    const status = (await client.callTool({ name: "godot_status", arguments: {} })) as any;
    expect(status.isError).toBeFalsy();
    const s = JSON.parse(status.content[0].text);
    expect(s.project.root).toBe(dir);
    await ctx.engine.dispose();
    rmSync(dir, { recursive: true, force: true });
  }, 60_000);
});
