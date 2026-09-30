#!/usr/bin/env node
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { loadConfig } from "./config.js";
import { createCtx } from "./mcp/helpers.js";
import { createServer, SERVER_NAME, SERVER_VERSION } from "./mcp/server.js";

async function main(): Promise<void> {
  const config = loadConfig();
  const ctx = createCtx(config);
  const server = createServer(ctx);
  ctx.engine.bindProcessCleanup();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  process.stderr.write(
    `[bismuth-mcp-godot] ${SERVER_NAME} ${SERVER_VERSION} готов | проект: ${config.projectRoot} | godot: ${config.godotBin}\n`,
  );

  const shutdown = async (code: number): Promise<void> => {
    try {
      await ctx.engine.dispose();
    } catch {
      /* игнорируем ошибки при выходе */
    }
    process.exit(code);
  };
  process.on("SIGINT", () => void shutdown(0));
  process.on("SIGTERM", () => void shutdown(0));
}

main().catch((err) => {
  process.stderr.write(`[bismuth-mcp-godot] фатальная ошибка запуска: ${err instanceof Error ? err.stack ?? err.message : String(err)}\n`);
  process.exit(1);
});
