#!/usr/bin/env bash
# Синтаксическая проверка GDScript-хоста и аддона моста: godot --headless --check-only
# Использование: scripts/check-gd.sh [каталог-проекта]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJ="${1:-$ROOT/test/fixtures/demo-project}"
GODOT="${GODOT_BIN:-godot}"

if [ ! -f "$PROJ/project.godot" ]; then
  echo "Нет project.godot в $PROJ" >&2
  exit 2
fi

# Раскладываем актуальные скрипты так же, как это делает MCP-сервер.
rm -rf "$PROJ/.mcp"
mkdir -p "$PROJ/.mcp/commands" "$PROJ/addons/bismuth_mcp_godot"
cp "$ROOT/godot/host/host.gd" "$ROOT/godot/host/variant.gd" "$PROJ/.mcp/"
cp "$ROOT"/godot/host/commands/*.gd "$PROJ/.mcp/commands/"
cp "$ROOT"/godot/editor_bridge/*.gd "$PROJ/addons/bismuth_mcp_godot/"
printf '# служебные файлы MCP-хоста: редактор их не сканирует\n' > "$PROJ/.mcp/.gdignore"

fail=0
check() {
  local rel="$1"
  local out
  out=$("$GODOT" --headless --path "$PROJ" --check-only -s "res://$rel" 2>&1 | grep -A2 -E 'SCRIPT ERROR' | head -40)
  if [ -n "$out" ]; then
    echo "=== $rel ==="
    echo "$out"
    fail=1
  fi
}

check ".mcp/host.gd"
check ".mcp/variant.gd"
for f in "$PROJ"/.mcp/commands/*.gd; do
  check ".mcp/commands/$(basename "$f")"
done
for f in "$PROJ"/addons/bismuth_mcp_godot/*.gd; do
  check "addons/bismuth_mcp_godot/$(basename "$f")"
done

if [ "$fail" -eq 0 ]; then
  echo "GDScript: синтаксис в порядке (хост + аддон моста)"
fi
exit "$fail"
