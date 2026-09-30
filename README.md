# Bismuth_MCP_Godot

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%E2%89%A520-5FA04E)](https://nodejs.org)
[![Model Context Protocol](https://img.shields.io/badge/MCP-1.31-8A2BE2)](https://modelcontextprotocol.io)
[![Godot](https://img.shields.io/badge/Godot-4.x-478cbf)](https://godotengine.org)

MCP-сервер, который даёт AI-агенту полноценный доступ к движку **Godot 4.x**: чтение и
правка сцен и ресурсов, интроспекция классов, запуск игры в управляемом headless-процессе,
покадровая отладка, ввод, скриншоты, проверка скриптов, диагностика через встроенный
GDScript LSP и мост к уже открытому редактору.

Сервер написан на TypeScript (Node ≥ 20), а вся работа с движком вынесена в GDScript-хост,
который запускается **внутри Godot**. Поэтому сцены, ресурсы и поведение игры агент
изучает настоящим движком, а не приблизительной реконструкцией формата файлов.

> Автор: [QkartBismuth](https://github.com/QkartBismuth) · лицензия MIT · версия 0.0.1

---

## Содержание

- [Возможности](#возможности)
- [Как это работает](#как-это-работает)
- [Требования](#требования)
- [Установка](#установка)
- [Подключение к MCP-клиенту](#подключение-к-mcp-клиенту)
- [Первый сеанс агента](#первый-сеанс-агента)
- [Справочник инструментов](#справочник-инструментов)
- [Формат значений Godot в JSON](#формат-значений-godot-в-json)
- [Редактор: мост и LSP](#редактор-мост-и-lsp)
- [Переменные окружения](#переменные-окружения)
- [Безопасность и ограничения](#безопасность-и-ограничения)
- [Разработка](#разработка)
- [Известные грабли Godot 4.x](#известные-грабли-godot-4x)
- [Лицензия](#лицензия)

---

## Возможности

| Область | Что умеет |
|---|---|
| **Сцены** | точное чтение `.tscn` (только реально сохранённые свойства, `ext_resource`, связи), дерево узлов, инспекция, создание сцен, транзакционное редактирование 14 операциями с dry-run и автобэкапами |
| **Игра** | запуск сцены в headless-хосте, пошаговое выполнение кадров, пауза, `time_scale`, инъекция ввода, вызов методов, чтение/запись свойств, отправка сигналов, скриншоты окна и отдельных узлов |
| **Справочник API** | классы, методы, свойства, сигналы, enum, константы через ClassDB; официальная документация из кэша `--dump-extension-api-with-docs`; поиск по всему API и по `class_name` проекта |
| **Код** | структура GDScript-файла с номерами строк и docstring, поиск использований символа, проверка синтаксиса всех скриптов, разбор ошибок компиляции |
| **Ресурсы** | чтение и запись любых Resource, создание ресурсов, поиск ассетов, обратные ссылки «где упоминается этот ресурс» |
| **Проект** | настройки `project.godot`, импорт ассетов, scaffold нового проекта, экспорт по пресетам, запуск тестов (GUT или свой раннер) |
| **Редактор** | мост к открытому редактору (открытие/правка/сохранение сцен, запуск проекта, лог, снимок окна) и диагностика через встроенный GDScript LSP |

## Как это работает

```
AI-агент ── MCP (stdio, JSON-RPC) ──▶ Bismuth_MCP_Godot (Node/TS)
                                          │  реестр инструментов, лимиты, песочница путей
                                          │  индекс API из --dump-extension-api-with-docs
                                          │
                                          ├─ TCP 127.0.0.1 (JSONL + одноразовый токен)
                                          │     └─▶ godot --headless --script res://.mcp/host.gd
                                          │           долгоживущий SceneTree-хост: ClassDB,
                                          │           ресурсы, сцены, живой рантайм, ввод, скриншоты
                                          ├─ разовые запуски CLI: --import, --check-only, --export-*
                                          ├─ LSP (Content-Length) ──▶ godot --editor --lsp-port N
                                          └─ TCP-сервер ◀── @tool-плагин addons/bismuth_mcp_godot
                                                (открытый редактор: сцены, запуск, лог, скриншот)
```

Ключевая идея: **один headless-процесс Godot живёт всё время сессии агента**. Он
поднимает автолоаны проекта, а сцены загружает в своё дерево — поэтому связка
«запустить игру → посмотреть дерево узлов → вызвать метод → сделать скриншот → проиграть
10 кадров» работает без перезапусков процесса.

**Протокол хоста.** Godot подключается к серверу (а не наоборот) и говорит на JSON-строк��х:
`{"type":"req","id":N,"cmd":"scene.tree","params":{…}}` → `{"type":"res","id":N,"ok":true,"data":{…}}`.
События (`step_complete`, `runtime_started`, `host_shutdown`) идут отдельными сообщениями.
Всё, что приходит в stdout/stderr процесса Godot, попадает в кольцевой буфер логов.

**Что сервер создаёт внутри Godot-проекта** (всё это игнорируется движком и исключается из VCS):

| Каталог | Содержимое |
|---|---|
| `.mcp/` | скрипты GDScript-хоста + `bridge.json` (порт и токен для редакторного плагина) |
| `.mcp-backups/` | автобэкапы сцен перед каждой записью |
| `.mcp-shots/` | PNG-скриншоты |

## Требования

- **Node.js ≥ 20.10** (проверено на 26.x)
- **Godot 4.x редакторной сборки** — на ней построены и host-скрипты, и аддон моста,
  и LSP. Проверено на **4.4.1** (GitHub Actions) и **4.7.2** (локально), Linux/AMD64
- Для скриншотов и рендера: графическая сессия (`DISPLAY` или `WAYLAND_DISPLAY`)

## Установка

```bash
git clone https://github.com/QkartBismuth/Bismuth_MCP_Godot.git
cd Bismuth_MCP_Godot
npm install
npm run build
```

`npm run build` собирает TypeScript в `dist/` и делает `dist/index.js` исполняемым.

Проверить, что всё видно (движок, проект, скриншоты, LSP, мост):

```bash
GODOT_PROJECT=/path/to/your/project node dist/cli.js
```

Убрать служебные каталоги из проекта:

```bash
GODOT_PROJECT=/path/to/your/project node dist/cli.js --clean
```

Можно установить глобально как команду:

```bash
npm link          # доступны команды bismuth-mcp-godot и bismuth-mcp-godot-doctor
```

Имя пакета в npm — `bismuth-mcp-godot`: спецификация npm не допускает верхний регистр
в имени пакета, поэтому в технических идентификаторах используется нижний регистр,
а человекочитаемое название — `Bismuth_MCP_Godot`.

## Подключение к MCP-клиенту

Сервер работает через stdio, поэтому в конфиге указывается только команда.
Каталог проекта фиксируется один раз: переменная `GODOT_PROJECT` (рекомендуется)
или текущий рабочий каталог клиента.

### opencode

`~/.config/opencode/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "bismuth-mcp-godot": {
      "type": "local",
      "command": ["node", "/путь/к/Bismuth_MCP_Godot/dist/index.js"],
      "environment": { "GODOT_PROJECT": "/путь/к/godot/проекту" },
      "enabled": true
    }
  }
}
```

### Claude Desktop

`claude_desktop_config.json` (`~/Library/Application Support/Claude/claude_desktop_config.json`
на macOS, `%APPDATA%\Claude\claude_desktop_config.json` на Windows):

```json
{
  "mcpServers": {
    "bismuth-mcp-godot": {
      "command": "node",
      "args": ["/путь/к/Bismuth_MCP_Godot/dist/index.js"],
      "env": { "GODOT_PROJECT": "/путь/к/godot/проекту" }
    }
  }
}
```

### Cursor / Windsurf / VS Code / любой клиент с MCP

```json
{
  "mcpServers": {
    "bismuth-mcp-godot": {
      "command": "node",
      "args": ["/путь/к/Bismuth_MCP_Godot/dist/index.js"],
      "env": { "GODOT_PROJECT": "/путь/к/godot/проекту" }
    }
  }
}
```

После правки конфига перезапустите клиент: MCP-серверы читаются при старте.

## Первый сеанс агента

Типичный цикл работы агента — от «понять проект» до «увидеть результат»:

```jsonc
// 1. Окружение
godot_status {}

// 2. Что в проекте
godot_project_info { input_actions: true }
godot_scene     { mode: "state", path: "res://scenes/main.tscn" }   // что реально записано в файле
godot_scene     { mode: "tree",  path: "res://scenes/main.tscn" }   // дерево узлов

// 3. Справка и код
godot_class     { mode: "info", class: "CharacterBody2D", sections: ["methods", "properties"] }
godot_script    { mode: "symbols", path: "res://scripts/player.gd" }

// 4. Правка сцены: сначала dry run, потом запись
godot_scene_edit { path: "res://scenes/main.tscn", save: false, ops: [
  { "op": "add_node", "parent": "Player", "type": "CollisionShape2D", "name": "Body",
    "props": { "shape": { "$": "ClassRef", "class": "CapsuleShape2D" } } }
]}
godot_scene_edit { /* те же ops */ , save: true }

// 5. Проверка и запуск
godot_script_check { dir: "res://scripts", boot_check: true }
godot_run         { mode: "start", render: true, scene: "res://scenes/main.tscn" }
godot_input       { mode: "action", action: "jump", pressed: true }
godot_run         { mode: "step", frames: 30 }
godot_screenshot  { node: "Player" }
godot_runtime     { mode: "get", node: "Player", property: "position" }
godot_logs        { mode: "errors" }
```

Готовый сценарий целиком можно посмотреть в `scripts/e2e-demo.mjs`
(`npm run build && node scripts/e2e-demo.mjs`): создание сцены из операций, проверка
скриптов, запуск с рендером, 60 кадров физики, скриншот и чтение живой позиции игрока.

## Справочник инструментов

Всего 23 инструмента. Схемы и описания отдаются клиенту автоматически; ниже — поведение
и важные параметры.

### Проект и окружение

| Инструмент | Поведение |
|---|---|
| `godot_status` | версия движка и бинарь, корень проекта, состояние host-процесса, режим рендера, готовность импорта, индекс документации, лимиты. `refresh_api: true` пересобирает индекс |
| `godot_project_info` | имя, features, главная сцена, автолоаны, слои физики/рендера, плагины, глобальные классы, пресеты экспорта. Флаги `input_actions`, `autoloads`, `global_classes` добавляют соответствующие разделы |
| `godot_project_settings` | `mode=list` (все ключи, опционально по `prefix`), `mode=get` (конкретные `keys`), `mode=set` (`items: [{key, value}]`, `save: true` пишет `project.godot`). Ключи указываются без секции: `display/window/size/viewport_width` |
| `godot_files` | `mode=list` (фильтры-глобы `include`/`exclude`, `*.gd` находит скрипты на любой вложенности), `read` (`offset`/`max_bytes`), `write` (`append`, автобэкап при перезаписи), `stat`, `restore` (вернуть файл из `.mcp-backups`) |
| `godot_assets` | `mode=search` — ресурсы по имени и типу (`Texture2D`, `PackedScene`, `Script`, …) с uid и размером; `mode=info` — метаданные и зависимости; `mode=references` — где ресурс упоминается в текстовых файлах |
| `godot_project_import` | `godot --headless --import`, разбор ошибок и списка переимпортированных файлов |
| `godot_project_scaffold` | новый проект: `project.godot`, `.gitignore`, `main.tscn`, скрипт, иконка, опционально карта ввода; сам импортирует |
| `godot_export` | `mode=presets` — список пресетов; `mode=export` — pack или бинарник, debug/release; `mode=test` — запуск тестов (GUT, `test_runner.gd` или своя `test_command`) с разбором результатов |

### Сцены и ресурсы

| Инструмент | Поведение |
|---|---|
| `godot_scene` | `mode=state` — точное содержимое `.tscn`: узлы, **только сохранённые свойства**, инстансы, группы, связи. `mode=tree` — дерево с диска или из живой игры (`source: live`), `props: saved\|all\|custom`. `mode=inspect` — свойства, сигналы, методы узла. `mode=create` — новая сцена |
| `godot_scene_edit` | батч операций над сценой; `save: false` (по умолчанию) — dry run, в ответе лог каждой операции |
| `godot_scene_backups` | список автобэкапов из `.mcp-backups` |
| `godot_resource` | `mode=info` (класс, uid, зависимости, размер изображения), `get` (свойства), `set` (запись, `save`/`save_as`), `create` (по `type` или `base` + скрипт) |

Операции `godot_scene_edit` (выполняются по порядку, первая ошибка останавливает батч):

| Операция | Ключевые поля |
|---|---|
| `add_node` | `parent`, `type`, `name`, `props`, `script`, `groups`, `index`/`after` |
| `instantiate_scene` | `parent`, `scene`, `name`, `props` |
| `remove_node` | `path` |
| `duplicate` | `path`, `name`, `flags` |
| `rename` | `path`, `name` |
| `reparent` | `path`, `new_parent`, `keep_transform` |
| `move` | `path`, `index` |
| `set_props` | `path`, `props` (вложенные пути вида `theme/colors/font_color`) |
| `group` | `path`, `add`, `remove` |
| `script` | `path`, `attach` или `detach: true` |
| `connect` / `disconnect` | `from` (или `path`), `signal`, `to`, `method`, `binds`, `flags` |
| `set_owner` | `path`, `owner` |
| `set_meta` | `path`, `key`, `value` |

Сцены сохраняются через `PackedScene` движка, поэтому корректно пишутся `owner`,
`ext_resource`, UID и связи. Перед записью создаётся бэкап в `.mcp-backups`.

### Рантайм

| Инструмент | Поведение |
|---|---|
| `godot_run` | `mode=start` (загрузить сцену в дерево хоста; `render: true` — перезапустить хост с реальным display-драйвером), `stop`, `status`, `step` (`frames` или `seconds`, после шага дерево автоматически останавливается), `configure` (`paused`, `time_scale`, `max_fps`, `fixed_fps`) |
| `godot_runtime` | `tree`, `inspect`, `find` (по имени, типу, группе, скрипту), `get`, `set`, `call`, `emit`, `connect` — по живой игре |
| `godot_input` | `action`, `key` (по имени: `SPACE`, `A`, `ESCAPE`), `mouse_button`, `mouse_motion`, `joy_button`, `release_all`. Работает и в headless |
| `godot_screenshot` | PNG окна или с кропом по узлу (`Control`/`Node2D`/`Node3D`); возвращает путь и само изображение |
| `godot_image` | текстура проекта как PNG-блок (визуальная проверка спрайтов, иконок, атласов) |
| `godot_logs` | буфер stdout/stderr, разбор `SCRIPT ERROR` в стек-трейсы, `errors` — только ошибки, курсор `since` для инкрементального чтения |

### Справочник и код

| Инструмент | Поведение |
|---|---|
| `godot_class` | `mode=info` (методы, свойства, сигналы, enum, константы; `sections` ограничивает набор, `include_docs: true` добавляет официальные описания), `search` (по API и `class_name` проекта), `props` (допустимые значения свойства, например enum), `inheritors` (наследники), `build_api_index` (пересобрать кэш документации) |
| `godot_script` | `mode=symbols` (функции, сигналы, переменные с `@export` и значениями по умолчанию, константы, enum, docstring, номера строк), `info`, `read` (диапазон строк), `references` (где вызывается символ) |
| `godot_script_check` | `--check-only` для всех `.gd` (параллельно, по пачкам) + опциональная `boot_check` — загрузка проекта в headless ради ошибок инициализации |

## Формат значений Godot в JSON

Свойства задаются и возвращаются в наглядном виде:

```jsonc
{ "$": "Vector2", "x": 100, "y": 0 }
{ "$": "Color", "hex": "#ff8800" }
{ "$": "Resource", "class": "Texture2D", "path": "res://art/hero.png" }
{ "$": "ClassRef", "class": "CircleShape2D" }
"Vector2(10, 20)"              // строковая запись тоже понимается
"theme/colors/font_color"      // вложенное свойство
"PackedStringArray(\"a\", \"b\")" // упакованные массивы
```

Тип подставляется автоматически по `property_list` цели, поэтому `{"energy": 2.5}`
на `PointLight2D` станет `float`, а `{"visible": true}` — `bool`. Массивы и словари
конвертируются рекурсивно.

## Редактор: мост и LSP

### Мост редактора

```jsonc
godot_editor { "mode": "install_bridge" }
```

Аддон `res://addons/bismuth_mcp_godot` копируется в проект, прописывается в секцию
`[editor_plugins]` файла `project.godot` и подключается к MCP-серверу по данным из
`.mcp/bridge.json` (переподключается сам при перезапуске сервера). После этого:

1. перезапустите редактор;
2. включите плагин: **Проект → Настройки плагинов → Bismuth MCP Godot Bridge**.

Дальше доступны `status`, `open_scene`, `save`, `reload`, `log`, `run`, `stop`,
`edit_scene` (правка открытой в редакторе сцены с автосохранением) и `screenshot`
(снимок окна редактора).

### GDScript LSP

`godot_lsp` подключается к встроенному языковому серверу Godot: сначала пробует уже
открытый редактор (порт 6005 или `GODOT_MCP_LSP_PORT`), иначе поднимает собственный
headless-редактор (первый вызов занимает 5–10 секунд). Режимы: `diagnostics` (ошибки
и предупреждения по файлам), `hover`, `definition`, `completion`, `symbols`,
`references`, `status`.

## Переменные окружения

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `GODOT_PROJECT` | текущий каталог | корень Godot-проекта |
| `GODOT_BIN` | `godot` | путь к бинарю движка |
| `GODOT_MCP_RENDER` | `0` | `1` — сразу запускать хост с рендером (нужно для скриншотов) |
| `GODOT_MCP_DISPLAY_DRIVER` | `x11` | `x11` или `wayland` для рендер-режима |
| `GODOT_MCP_RENDERING_DRIVER` | `opengl3` | `opengl3` или `vulkan` |
| `GODOT_MCP_RENDER_WIDTH` / `_HEIGHT` | `1152` / `648` | размер окна в рендер-режиме |
| `GODOT_MCP_WINDOW_POSITION` | `0,0` | положение окна (можно увести за пределы экрана) |
| `GODOT_MCP_PORT` | `0` (случайный) | фиксированный порт TCP-моста |
| `GODOT_MCP_LSP_PORT` | `6005` | порт LSP уже открытого редактора |
| `GODOT_MCP_TIMEOUT_MS` | `30000` | таймаут команд хоста |
| `GODOT_MCP_START_TIMEOUT_MS` | `45000` | таймаут запуска host-процесса и импорта |
| `GODOT_MCP_STEP_TIMEOUT_MS` | `60000` | таймаут пошагового выполнения |
| `GODOT_MCP_CLI_TIMEOUT_MS` | `180000` | таймаут разовых запусков CLI |
| `GODOT_MCP_MAX_LOG_LINES` | `4000` | размер кольцевого буфера логов |
| `GODOT_MCP_MAX_RESPONSE_BYTES` | `8388608` | лимит размера ответа хоста |
| `GODOT_MCP_CACHE` | `~/.cache/bismuth-mcp-godot` | кэш индекса API |
| `GODOT_MCP_VERBOSE` | `0` | `1` — весь stdout/stderr Godot в stderr MCP-сервера |
| `GODOT_MCP_ALLOW_EVAL` | `0` | резерв для запуска произвольного GDScript |

## Безопасность и ограничения

- **Песочница.** Все файловые операции ограничены корнем проекта; попытка выйти за его
  пределы возвращает ошибку `sandbox`.
- **Локальный транспорт.** TCP-мост слушает только `127.0.0.1` и требует одноразовый
  токен, который каждый раз генерируется заново при старте сервера.
- **Ничего не меняется без `save`.** Правки сцен и ресурсов применяются в памяти, пока
  не передан `save: true`; перед записью сцены создаётся бэкап.
- **Лимиты.** Размер ответа ограничен (по умолчанию 8 МБ) — при превышении приходит
  подсказка уменьшить выборку (`max_nodes`, `props`, `limit`).
- **Скриншоты требуют реального display-драйвера.** В headless рендерер фиктивный;
  сервер вернёт ошибку `no_renderer` с инструкцией, как включить рендер.
- **Рендер-режим открывает настоящее окно Godot** — на время работы агента.
- Если игра вызывает `get_tree().quit()`, процесс хоста завершается: сервер пометит
  рантайм как остановленный и поднимет новый при следующем обращении.
- Два экземпляра редактора на одном проекте конфликтуют, поэтому `godot_lsp` сначала
  подключается к уже открытому редактору, и только потом поднимает свой.

## Разработка

```bash
npm install
npm run build        # tsc + chmod точки входа
npm run typecheck    # проверка типов без сборки
npm test             # 29 тестов: интеграционные (реальный Godot), MCP-уровень, юнит-тесты
npm run check:gd     # синтаксис всех GDScript-файлов хоста и аддона
npm run doctor       # диагностика окружения
node scripts/e2e-demo.mjs   # полный демо-цикл агента
```

### Структура

```
src/
  index.ts              точка входа: stdio MCP-сервер
  cli.ts                doctor / doctor --clean
  config.ts             env, поиск корня проекта, песочница путей
  engine/
    godot.ts            менеджер host-процесса, установка скриптов, аддона, runCli
    bridge.ts           TCP-мост: пиры, протокол JSONL, роутинг запросов
    logs.ts             кольцевой буфер логов, разбор ошибок и трассировок
    editor.ts           менеджер редактора и LSP-сессии
    apiIndex.ts         кэш extension_api.json: классы, методы, поиск
  lsp/client.ts         клиент GDScript LSP поверх TCP
  mcp/
    helpers.ts          контекст, ответы, ошибки, типы инструментов
    server.ts           регистрация 23 инструментов
  tools/
    project.ts scene.ts inspect.ts runtime.ts editor.ts
godot/
  host/                 GDScript-хост: host.gd, variant.gd, commands/*.gd
  editor_bridge/        @tool-плагин редактора: plugin.cfg, plugin.gd, ops.gd
test/
  unit.test.ts          config, песочница, логи, индекс API
  integration.test.ts   сценарии на реальном Godot (копия фикстуры в /tmp)
  mcp.test.ts           протокол MCP через in-memory транспорт
  fixtures/demo-project/  маленький проект Godot 4 для тестов
```

### Как отлаживать протокол

```bash
GODOT_MCP_VERBOSE=1 node dist/index.js        # весь вывод Godot в stderr
bash scripts/check-gd.sh                      # синтаксис GDScript (--check-only)
```

Инструкции для ИИ-агентов, работающих с этим репозиторием, — в [AGENT.md](AGENT.md).

## Известные грабли Godot 4.x

Зафиксированы при разработке, полезны при доработке хоста:

1. `--script` требует наследования от `MainLoop`/`SceneTree` (даже вместе с `-e`),
   но **автолоаны проекта при этом поднимаются** — на этом построен рантайм.
2. Статус `StreamPeerTCP` обновляется только после `poll()`: нельзя читать `get_status()`
   до опроса сокета, иначе соединение не поднимется.
3. `SceneTree::process()` вызывает `MainLoop::process()` первым — обработчик `_process`
   хоста выполняется до обработки узлов, и в нём удобно читать сокет.
4. Предупреждение `inference_on_variant` в 4.7 считается ошибкой; в файлах хоста оно
   подавлено на уровне файла через `@warning_ignore_start`.
5. Оператор `%` со списком аргументов внутри словаря ломает парсер GDScript — используется
   обёртка `fmt()`.
6. `PackedScene.pack()` не требует `owner == self`, но включает только узлы с
   `owner == root`; содержимое подсцен оставляется внутри инстансов.
7. Часть API появилась только в 4.5+: `FileAccess.get_size()` и
   `SceneState.get_base_scene_state()`. Для совместимости с 4.4 используется
   `host.file_size()` (через `get_length()`) и проверка `has_method()`.
8. `RegEx.new()` не принимает аргументы — шаблон задаётся через `compile()`.
9. `ResourceLoader.get_resource_type()` не доступен из скриптов — тип определяется по
   карте «расширение → класс», собранной из `ClassDB`.
10. Часть методов движка отдаёт в `args` не словари — значения приводятся к словарю
    перед разбором.
11. Списком `[1, 2, 3][:limit]` нельзя взять срез прямо в литерале словаря — результат
    вычисляется заранее.

## Лицензия

[MIT](LICENSE) © 2026 [QkartBismuth](https://github.com/QkartBismuth)
