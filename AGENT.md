# AGENT.md

Инструкции для ИИ-агента, который работает с кодовой базой **Bismuth_MCP_Godot**
(MCP-сервер для Godot 4.x). Прочитай файл целиком перед правками.

## Что это за проект

TypeScript-сервер (Node ≥ 20, ESM, сборка `tsc` → `dist/`), который поднимает **MCP-инструменты
для Godot 4.x**. Логика работы с движком вынесена в GDScript-хост, запускаемый
внутри Godot: `godot --headless --script res://.mcp/host.gd`. Сервер общается с хостом
по TCP (`127.0.0.1`, JSON-строки, одноразовый токен), с редактором — через @tool-плагин
в `addons/bismuth_mcp_godot`, с языковым сервером Godot — по протоколу LSP.

Три независимых слоя, которые нельзя менять по отдельности без синхронизации:

| Слой | Файлы | Комментарий |
|---|---|---|
| TypeScript-сервер | `src/**/*.ts` | транспорт, реестр инструментов, песочница, лимиты |
| GDScript-хост | `godot/host/**` | вся работа со сценами, ресурсами, рантаймом |
| Аддон редактора | `godot/editor_bridge/**` | те же операции над сценой, открытой в редакторе |

## Команды

```bash
npm run build        # tsc -p tsconfig.json + chmod dist/index.js
npm run typecheck    # tsc --noEmit
npm test             # 29 тестов (нужен установленный Godot; ~20 c)
npm run check:gd     # синтаксис GDScript хоста и аддона (godot --check-only)
npm run doctor       # диагностика окружения (GODOT_PROJECT обязателен)
npm run clean        # удалить .mcp/, .mcp-backups/, .mcp-shots/ из проекта
node scripts/e2e-demo.mjs   # полный цикл: сцена → запуск → 60 кадров → скриншот
```

Тесты работают на **копии** `test/fixtures/demo-project` во временном каталоге
(`test/helpers.ts`), поэтому мутации сцен не портят репозиторий.

## Жёсткие правила

1. **Не ломай протокол.** Формат сообщений хоста — `{"type":"req","id":N,"cmd":...,"params":...}`
   и `{"type":"res","id":N,"ok":true|false,"data"|"error":...}`. Ответ всегда содержит
   `"id"` запроса, иначе Node-клиент его не найдёт.
2. **Проверяй GDScript перед коммитом.** `npm run check:gd` обязан проходить: 4.7
   трактует `inference_on_variant` как ошибку, а `% [...]` внутри словаря ломает парсер
   (используй `fmt()`).
3. **Любая новая команда хоста** добавляется в список `commands()` соответствующего
   модуля (`godot/host/commands/cmd_*.gd`) и в реестр инструментов (`src/tools/*.ts`).
   Модуль реализует `handle(cmd, params) -> Dictionary` и возвращает `host.ok(data)`
   либо `host.err(message, code)`; допустимо вернуть «сырую» нагрузку — диспетчер
   хоста обернёт её.
4. **Коды ошибок** — snake_case: `not_found`, `bad_params`, `sandbox`, `no_runtime`,
   `no_renderer`, `op_failed`, `unknown_command`, `save_error`, `parse_error`.
5. **Песочница.** Любой путь от пользователя проверяется через `ensureInsideProject()`
   (`src/mcp/helpers.ts`); в хосте — `host.safe_res_path()`. Не обходи эти проверки.
6. **Ничего не пиши на диск без явного `save`.** `scene.apply_ops` и `resource.set`
   применяют изменения в памяти, пока не передан `save: true`.
7. **Ошибки показывай агенту, а не глотай.** Бросай `EngineError(message, code, hint?)`
   — `defineTool` превратит его в `isError: true` с понятным текстом.
8. **Не трогай конфиги MCP-клиентов пользователя** без прямой просьбы; в README лежат
   готовые примеры.

## Где что менять

| Задача | Файлы |
|---|---|
| Новый инструмент | `src/tools/<group>.ts` + регистрация в `src/mcp/server.ts` |
| Работа со сценами/узлами | `godot/host/commands/cmd_scene.gd`, `cmd_runtime.gd` |
| Файлы, настройки, инфо о проекте | `godot/host/commands/cmd_core.gd` |
| Ресурсы и ассеты | `godot/host/commands/cmd_resource.gd` |
| Справка по API | `godot/host/commands/cmd_classdb.gd` + `src/engine/apiIndex.ts` |
| Скриншоты и изображения | `godot/host/commands/cmd_capture.gd` |
| Запуск/остановка host-процесса, рендер | `src/engine/godot.ts` |
| Транспорт и роутинг пиров | `src/engine/bridge.ts` |
| LSP | `src/lsp/client.ts`, `src/engine/editor.ts` |
| Описания для агента | `README.md` (раздел «Справочник инструментов»), `src/mcp/server.ts` (`INSTRUCTIONS`) |

## Соглашения

- TypeScript: `strict`, `noUncheckedIndexedAccess`, ESM-импорты с расширением `.js`,
  без `any` в публичных сигнатурах (внутри хендлеров `ToolArgs` — `any` допустим).
- Ответы инструментов — `text(json)` или `textWithImage(json, path)`; в JSON значения
  Godot сериализуются как `{"$":"Vector2","x":1,"y":2}` (см. `godot/host/variant.gd`).
- GDSScript: типизация переменных явная (`var x: Node = ...`), никаких `class_name`
  в служебных файлах (иначе они зарегистрируются в проекте пользователя), никаких
  рекурсивных лямбд, никаких spread-вызовов (`callv` вместо `f(...args)`).
- Комментарии и сообщения об ошибках — по-русски, как в остальном проекте.
- Публичные файлы проекта: `README.md` (пользовательская документация) и `AGENT.md` (этот файл).

## Проверка перед завершением задачи

```bash
npm run typecheck && npm run check:gd && npm test
```

Если менялся транспорт, рантайм или рендер — дополнительно `node scripts/e2e-demo.mjs`
(должен напечатать `позиция игрока` с изменившимся `y` и создать PNG в `.mcp-shots/`).

## Известные особенности Godot 4.7 (не «чинить»)

Список из 11 пунктов — в README, раздел «Известные грабли Godot 4.x». Ключевые:
`StreamPeerTCP.get_status()` требует предварительного `poll()`; `pack()` включает только
узлы с `owner == root`; `inference_on_variant` — ошибка; `RegEx.new()` без аргументов;
`ResourceLoader.get_resource_type()` недоступен скриптам; `FileAccess.get_size()` и
`SceneState.get_base_scene_state()` есть только начиная с 4.5 (используй
`host.file_size()` и `has_method`).
