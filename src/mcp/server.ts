import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { defineTool, type Ctx, type Register } from "./helpers.js";
import { registerProjectTools, registerBackupTools } from "../tools/project.js";
import { registerSceneTools } from "../tools/scene.js";
import { registerInspectTools } from "../tools/inspect.js";
import { registerRuntimeTools } from "../tools/runtime.js";
import { registerEditorTools } from "../tools/editor.js";

export const SERVER_NAME = "bismuth-mcp-godot";
export const SERVER_VERSION = "0.0.1";

const INSTRUCTIONS = `MCP-сервер для Godot 4.x. Проект определяется один раз при старте (GODOT_PROJECT или текущий каталог).

Типичный цикл работы:
1. godot_status — проверка окружения (версия движка, хост, рендер, индекс API).
2. godot_project_info / godot_scene { mode: "state" } — понять структуру проекта и сцены.
3. godot_class / godot_script — справка по API и по коду проекта.
4. godot_scene_edit { save: false } —Dry run изменения сцены, затем save: true (с бэкапом).
5. godot_run { mode: "start", render: true } + godot_screenshot + godot_input + godot_run { mode: "step" } — проверка поведения игры.
6. godot_script_check — валидация правок скриптов.

Значения свойств передаются как JSON: примитивы, строки вида "Vector2(10, 20)" или объекты
{"$":"Vector2","x":10,"y":20}, {"$":"Color","hex":"#ff8800"}, {"path":"res://icon.svg"} для ресурсов.
Пути сцен: "scenes/main.tscn" (или res://scenes/main.tscn).`;

export function createServer(ctx: Ctx): McpServer {
  const server = new McpServer(
    { name: SERVER_NAME, version: SERVER_VERSION },
    {
      capabilities: { tools: {} },
      instructions: INSTRUCTIONS,
    },
  );

  const register: Register = (name, def, handler) => defineTool(server, name, def, handler, ctx);

  registerProjectTools(register);
  registerBackupTools(register);
  registerSceneTools(register);
  registerInspectTools(register);
  registerRuntimeTools(register);
  registerEditorTools(register);

  return server;
}
