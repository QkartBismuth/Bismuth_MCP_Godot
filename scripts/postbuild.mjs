import { chmodSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const entry = path.join(here, "..", "dist", "index.js");
try {
  chmodSync(entry, 0o755);
} catch {
  /* нет dist — сборка не завершена */
}
if (!existsSync(path.join(here, "..", "godot", "host", "host.gd"))) {
  console.error("[bismuth-mcp-godot] ВНИМАНИЕ: не найден каталог godot/host");
}
