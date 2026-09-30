@tool
extends EditorPlugin
# Мост к MCP-серверу Bismuth_MCP_Godot. Параметры подключения читаются из res://.mcp/bridge.json,
# который перезаписывает MCP-сервер при каждом старте; плагин сам переподключается при смене порта.

const BRIDGE_FILE := "res://.mcp/bridge.json"
const RECONNECT_INTERVAL := 2.0
const PROTOCOL := 1

const OPS := preload("res://addons/bismuth_mcp_godot/ops.gd")

var _peer: StreamPeerTCP = null
var _rx := ""
var _connected := false
var _next_try := 0.0
var _known_port := -1
var _known_token := ""
var _shot_dir := "user://"


func _enter_tree() -> void:
	set_process(true)
	_shot_dir = "res://.mcp-shots"
	DirAccess.make_dir_recursive_absolute(_shot_dir)
	print("[bismuth-mcp-godot] мост редактора: ожидание %s" % BRIDGE_FILE)


func _exit_tree() -> void:
	_disconnect()


func _process(delta: float) -> void:
	_pump()
	if _connected:
		return
	_next_try -= delta
	if _next_try > 0.0:
		return
	_next_try = RECONNECT_INTERVAL
	_try_connect()


func _read_config() -> Dictionary:
	if not FileAccess.file_exists(BRIDGE_FILE):
		return {}
	var text := FileAccess.get_file_as_string(BRIDGE_FILE)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


func _try_connect() -> void:
	if _peer != null:
		return
	var cfg := _read_config()
	var port := int(cfg.get("port", 0))
	var token := str(cfg.get("token", ""))
	if port <= 0 or token.is_empty():
		return
	_known_port = port
	_known_token = token
	_peer = StreamPeerTCP.new()
	_peer.connect_to_host("127.0.0.1", port)


func _disconnect() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	_connected = false
	_rx = ""


func _pump() -> void:
	if _peer == null:
		return
	_peer.poll()
	var st := _peer.get_status()
	if st == StreamPeerTCP.STATUS_ERROR:
		_peer = null
		_connected = false
		return
	if not _connected:
		if st != StreamPeerTCP.STATUS_CONNECTED:
			return
		_connected = true
		_send({
			"type": "hello",
			"kind": "editor",
			"protocol": PROTOCOL,
			"token": _known_token,
			"engine": Engine.get_version_info(),
			"project": ProjectSettings.globalize_path("res://"),
			"display": "editor",
			"pid": OS.get_process_id(),
		})
		print("[bismuth-mcp-godot] мост редактора подключён к порту %d" % _known_port)
		return
	while _peer.get_available_bytes() > 0:
		var chunk: Array = _peer.get_data(_peer.get_available_bytes())
		if int(chunk[0]) != OK:
			_disconnect()
			return
		_rx += (chunk[1] as PackedByteArray).get_string_from_utf8()
	var nl := _rx.find("\n")
	while nl != -1:
		var line := _rx.substr(0, nl)
		_rx = _rx.substr(nl + 1)
		if not line.strip_edges().is_empty():
			_handle(line)
		nl = _rx.find("\n")


func _handle(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	if msg.get("type") != "req":
		return
	var id := int(msg.get("id", -1))
	var cmd := str(msg.get("cmd", ""))
	var params: Dictionary = msg.get("params", {}) if typeof(msg.get("params")) == TYPE_DICTIONARY else {}
	var result: Dictionary = _dispatch(cmd, params)
	_send({
		"type": "res",
		"id": id,
		"ok": not result.has("error"),
		"error": result.get("error", null),
		"code": result.get("code", "error"),
		"data": result.get("data", null),
	})


func _send(msg: Dictionary) -> void:
	if _peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	_peer.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())


func _dispatch(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"status":
			return {"data": {
				"connected": true,
				"port": _known_port,
				"edited_scene": String(_edited_scene_path()),
				"root": _describe_root(),
				"project_path": ProjectSettings.globalize_path("res://"),
				"play_scene": get_editor_interface().get_playing_scene(),
			}}
		"open_scene":
			var path := str(p.get("path", ""))
			if path.is_empty():
				return {"error": "не указан path", "code": "bad_params"}
			if not ResourceLoader.exists(path):
				return {"error": "сцена не найдена: %s" % path, "code": "not_found"}
			get_editor_interface().open_scene_from_path(path)
			var opened: Dictionary = {"opened": path, "root": _describe_root()}
			return {"data": opened}
		"save_scene":
			var root := get_editor_interface().get_edited_scene_root()
			if root == null:
				return {"error": "нет открытой сцены", "code": "no_scene"}
			var err := get_editor_interface().save_scene()
			if err != OK:
				return {"error": "save_scene вернул %s" % error_string(err), "code": "save_error"}
			var saved: Dictionary = {"saved": root.scene_file_path, "path": _edited_scene_path()}
			return {"data": saved}
		"reload_scene":
			var current := _edited_scene_path()
			if current == "":
				return {"error": "нет открытой сцены", "code": "no_scene"}
			get_editor_interface().reload_scene_from_file(current)
			var reloaded: String = current
			return {"data": {"reloaded": reloaded}}
		"run_project":
			get_editor_interface().play_main_scene()
			var scene: String = _played()
			return {"data": {"running": true, "scene": scene}}
		"stop_project":
			get_editor_interface().stop_playing_scene()
			var stopped: Dictionary = {"running": false}
			return {"data": stopped}
		"log":
			return {"data": {"log": _log_tail(int(p.get("limit", 100))), "path": "user://logs/godot.log"}}
		"edit_scene":
			var root2 := get_editor_interface().get_edited_scene_root()
			if root2 == null:
				return {"error": "нет открытой сцены", "code": "no_scene"}
			var applier := OPS.new()
			applier.host = self
			var applied: Dictionary = applier.apply(root2, p.get("ops", []))
			if applied.has("error"):
				return {"error": str(applied["error"]), "code": "op_failed", "data": {"log": applied.get("log", [])}}
			if bool(p.get("save", true)):
				var serr := get_editor_interface().save_scene()
				if serr != OK:
					return {"error": "save_scene вернул %s" % error_string(serr), "code": "save_error"}
			var result: Dictionary = {"scene": _edited_scene_path(), "saved": bool(p.get("save", true)), "log": applied.get("log", [])}
			return {"data": result}
		"screenshot":
			return _screenshot(p)
	return {"error": "неизвестная команда: %s" % cmd, "code": "unknown_command"}


func _edited_scene_path() -> String:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return ""
	return root.scene_file_path


func _played() -> String:
	var scene: String = get_editor_interface().get_playing_scene()
	if scene == null or scene == "":
		return ""
	return scene


func _describe_root() -> Dictionary:
	var root := get_editor_interface().get_edited_scene_root()
	if root == null:
		return {}
	var script_path := ""
	if root.get_script() != null:
		script_path = root.get_script().resource_path
	return {
		"name": str(root.name),
		"type": root.get_class(),
		"children": root.get_child_count(),
		"script": script_path,
	}


func _log_tail(limit: int) -> Array:
	var out := []
	var path := OS.get_user_data_dir().path_join("logs/godot.log")
	if not FileAccess.file_exists(path):
		path = ProjectSettings.globalize_path("user://logs/godot.log")
	if not FileAccess.file_exists(path):
		return out
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var start := maxi(0, lines.size() - limit)
	for i in range(start, lines.size()):
		var line: String = lines[i]
		if not line.strip_edges().is_empty():
			out.append(line)
	return out


func _screenshot(p: Dictionary) -> Dictionary:
	var image := get_editor_interface().get_base_control().get_viewport().get_texture().get_image()
	if image == null or image.is_empty():
		return {"error": "не удалось получить кадр редактора", "code": "empty_image"}
	var out := str(p.get("path", _shot_dir.path_join("editor_%d.png" % Time.get_ticks_msec())))
	if not out.begins_with("res://"):
		out = "res://.mcp-shots/editor_%d.png" % Time.get_ticks_msec()
	var err := image.save_png(out)
	if err != OK:
		return {"error": "save_png вернул %s" % error_string(err), "code": "save_error"}
	return {"data": {
		"path": out,
		"real_path": ProjectSettings.globalize_path(out),
		"size": {"width": image.get_width(), "height": image.get_height()},
	}}
