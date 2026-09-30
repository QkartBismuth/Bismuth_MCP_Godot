# Changelog

Все значимые изменения проекта Bismuth_MCP_Godot фиксируются здесь.
Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версионирование — [Semantic Versioning](https://semver.org/lang/ru/).

## [0.0.1] — 2026-09-30

Первый публичный релиз: MCP-сервер, дающий AI-агенту полный доступ к Godot 4.x.

### Добавлено

**Транспорт и архитектура**

- MCP-сервер на TypeScript (Node ≥ 20, ESM), stdio-транспорт, 23 инструмента.
- Долгоживущий headless-процесс Godot (`godot --headless --script res://.mcp/host.gd`),
  обслуживаемый по TCP на `127.0.0.1` (JSON-строки, одноразовый токен на сессию).
- GDScript-хост поднимает автолоаны проекта и загружает сцены в своё дерево, поэтому
  инспекция рантайма, пошаговое выполнение, ввод и скриншоты работают без перезапусков.
- Сцены и ресурсы редактируются через `PackedScene` движка: корректно сохраняются
  `owner`, `ext_resource`, UID и связи.
- Мост к открытому редактору через `@tool`-плагин и диагностика через встроенный GDScript LSP.

**Инструменты**

- `godot_status`, `godot_project_info`, `godot_project_settings`, `godot_files`,
  `godot_assets`, `godot_project_import`, `godot_project_scaffold`, `godot_export`.
- `godot_scene` (точное содержимое `.tscn`, дерево, инспекция, создание),
  `godot_scene_edit` (14 операций, dry-run по умолчанию, автобэкапы), `godot_scene_backups`.
- `godot_run`, `godot_runtime`, `godot_input`, `godot_screenshot`, `godot_image`, `godot_logs`.
- `godot_class` (ClassDB + документация из `--dump-extension-api-with-docs`), `godot_script`,
  `godot_script_check`, `godot_resource`.
- `godot_lsp` (diagnostics, hover, definition, completion, symbols, references) и
  `godot_editor` (status, install_bridge, open_scene, save, reload, log, run, stop, edit_scene, screenshot).

**Эксплуатация**

- `node dist/cli.js` — doctor: проверка бинаря, проекта, импорта, хоста, скриншотов, LSP, моста, кэша.
- `node dist/cli.js --clean` — удаление служебных каталогов `.mcp*` из проекта.
- `scripts/check-gd.sh` — проверка синтаксиса всех GDScript-файлов хоста и аддона.
- `scripts/e2e-demo.mjs` — полный демо-цикл агента.
- GitHub Actions: Node 22 + Godot 4.4.1, `npm ci`, typecheck, проверка GDScript, тесты, сборка.
- `AGENT.md` — инструкции для ИИ-агентов, дорабатывающих репозиторий.

**Надёжность**

- Сервер стартует в любом каталоге: без Godot-проекта `godot_status` объясняет
  ситуацию, остальные инструменты возвращают `no_project`.
- Импорт `godot --import` выполняется в фоне; на больших проектах инструменты
  возвращают `importing` вместо блокировки до таймаута.
- Автоперезапуск упавшего host-процесса с повтором идемпотентных команд.
- Песочница файловых операций, лимит размера ответа, кольцевой буфер логов
  с разбором `SCRIPT ERROR` в стек-трейсы.

### Исправлено

- Совместимость с Godot 4.4: `FileAccess.get_size()` и `SceneState.get_base_scene_state()`
  появились только в 4.5 — заменены на `host.file_size()` (через `get_length()`)
  и проверку `has_method()`. Проверено на 4.4.1 и 4.7.2.
- Шаблон `godot_project_scaffold` больше не содержит выдуманный `uid://`: сгенерированный
  проект сразу импортируется и запускается.
- Фильтры `godot_files` (`*.gd` находит скрипты на любой вложенности), разбор
  результатов `scene.create`, синхронизация `package-lock.json` с `package.json`.

### Проверено

- 31 тест: интеграционные сценарии на реальном движке, протокол MCP через
  in-memory транспорт, юнит-тесты серверной части.
- Полный цикл агента на Godot 4.7.2: создание сцены из операций → проверка скриптов →
  запуск с рендером → 60 кадров физики → скриншот → чтение живой позиции игрока.

[0.0.1]: https://github.com/QkartBismuth/Bismuth_MCP_Godot/releases/tag/v0.0.1
