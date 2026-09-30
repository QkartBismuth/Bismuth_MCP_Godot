
@warning_ignore_start("inference_on_variant")
extends SceneTree
# MCP-хост Godot: долгоживущий headless-процесс, обслуживающий команды MCP-сервера по TCP.
# Запускается: godot --headless --path <project> --script res://.mcp/host.gd
# Порт и токен передаются через переменные окружения GODOT_MCP_PORT / GODOT_MCP_TOKEN.

const V := preload("res://.mcp/variant.gd")

const CMD_CORE := preload("res://.mcp/commands/cmd_core.gd")
const CMD_CLASSDB := preload("res://.mcp/commands/cmd_classdb.gd")
const CMD_RESOURCE := preload("res://.mcp/commands/cmd_resource.gd")
const CMD_SCENE := preload("res://.mcp/commands/cmd_scene.gd")
const CMD_SCRIPT := preload("res://.mcp/commands/cmd_script.gd")
const CMD_RUNTIME := preload("res://.mcp/commands/cmd_runtime.gd")
const CMD_CAPTURE := preload("res://.mcp/commands/cmd_capture.gd")

const PROTOCOL := 1
const MAX_MESSAGE_BYTES := 8 * 1024 * 1024
const CONNECT_RETRY_MS := 100
const DEFAULT_STEP_FPS := 0
const IDLE_MAX_FPS := 60

# --- соединение ---------------------------------------------------------------
var _peer: StreamPeerTCP = null
var _rx := PackedByteArray()
var _port := 0
var _token := ""
var _next_connect_at := 0
var _connected := false
var _closing := false

# --- диспетчеризация ----------------------------------------------------------
var _commands := {}
var _modules := {}
var _deferred: Array[Dictionary] = []
var _inflight := 0
var current_id := -1

# --- рантайм ------------------------------------------------------------------
var _runtime_root: Node = null
var _runtime_scene := ""
var _runtime_started_at := 0
var _runtime_paused_by_step := false
var _user_paused := false
var _step_budget := 0
var _step_id := -1
var _step_started_frame := 0
var _step_started_ms := 0
var _max_fps := IDLE_MAX_FPS
var _fps_sample_frames := 0
var _fps_sample_ms := 0
var _fps := 0.0
var _last_error := ""

# --- кэши ---------------------------------------------------------------------
var _prop_defaults := {}


func _initialize() -> void:
	_port = int(OS.get_environment("GODOT_MCP_PORT"))
	_token = OS.get_environment("GODOT_MCP_TOKEN")
	Engine.max_fps = _max_fps
	_register()
	print(JSON.stringify({
		"type": "boot",
		"protocol": PROTOCOL,
		"pid": OS.get_process_id(),
		"engine": Engine.get_version_info(),
		"project": ProjectSettings.globalize_path("res://"),
		"display": DisplayServer.get_name(),
		"port": _port,
	}, " "), "\n")


func _register() -> void:
	_modules = {
		"core": CMD_CORE.new(),
		"classdb": CMD_CLASSDB.new(),
		"resource": CMD_RESOURCE.new(),
		"scene": CMD_SCENE.new(),
		"script": CMD_SCRIPT.new(),
		"runtime": CMD_RUNTIME.new(),
		"capture": CMD_CAPTURE.new(),
	}
	for key: String in _modules:
		var mod: Object = _modules[key]
		mod.host = self
		for cmd_name: String in mod.commands():
			_commands[cmd_name] = [mod, cmd_name]


func _process(_delta: float) -> bool:
	_tick_metrics()
	_ensure_connection()
	_pump_socket()
	_run_deferred()
	_tick_step()
	return false


func _finalize() -> void:
	if _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		_send({"type": "event", "event": "host_shutdown", "data": {"error": _last_error}})


# --- сеть ---------------------------------------------------------------------

func _ensure_connection() -> void:
	if _connected or _closing:
		return
	var now := Time.get_ticks_msec()
	if _port <= 0:
		print("MCP: GODOT_MCP_PORT не задан, хост работает пассивно\n")
		_closing = true
		return
	if _peer != null:
		# Соединение уже устанавливается: pump дождётся статуса CONNECTED.
		if _peer.get_status() == StreamPeerTCP.STATUS_ERROR:
			_peer = null
		else:
			return
	if now < _next_connect_at:
		return
	_next_connect_at = now + CONNECT_RETRY_MS
	_peer = StreamPeerTCP.new()
	_peer.connect_to_host("127.0.0.1", _port)


func _pump_socket() -> void:
	if _peer == null:
		return
	# Статус StreamPeer обновляется только после poll(), поэтому сначала опрашиваем сокет.
	_peer.poll()
	var st := _peer.get_status()
	if st == StreamPeerTCP.STATUS_ERROR:
		_drop_connection("socket error")
		return
	if st != StreamPeerTCP.STATUS_CONNECTED:
		return
	if not _connected:
		_connected = true
		_peer.set_no_delay(true)
		_send({
			"type": "hello",
			"protocol": PROTOCOL,
			"token": _token,
			"pid": OS.get_process_id(),
			"engine": Engine.get_version_info(),
			"project": ProjectSettings.globalize_path("res://"),
			"display": DisplayServer.get_name(),
			"argv": OS.get_cmdline_user_args(),
		})
	while _peer.get_available_bytes() > 0:
		var chunk: Array = _peer.get_data(_peer.get_available_bytes())
		if int(chunk[0]) != OK:
			_drop_connection("read error")
			return
		_rx.append_array(chunk[1])
	if _rx.size() > MAX_MESSAGE_BYTES * 2:
		_drop_connection("rx buffer overflow")
		return
	var nl := _rx.find(10)
	while nl != -1:
		var line: PackedByteArray = _rx.slice(0, nl)
		_rx = _rx.slice(nl + 1)
		if line.size() > 0:
			_handle_line(line.get_string_from_utf8())
		nl = _rx.find(10)


func _drop_connection(reason: String) -> void:
	if _connected:
		print("MCP: соединение закрыто (%s), хост завершается\n" % reason)
	_closing = true
	_connected = false
	quit(0)


func _handle_line(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var msg: Dictionary = parsed
	if msg.has("type") and msg["type"] == "ack":
		return
	var id: int = int(msg.get("id", -1))
	var cmd: String = str(msg.get("cmd", ""))
	var params: Dictionary = msg.get("params", {}) if typeof(msg.get("params")) == TYPE_DICTIONARY else {}
	if cmd == "ping":
		respond(id, ok({"pong": true, "time": Time.get_ticks_msec()}))
		return
	if not _commands.has(cmd):
		respond(id, err("Неизвестная команда: %s" % cmd, "unknown_command"))
		return
	_inflight += 1
	var entry: Array = _commands[cmd]
	var mod: Object = entry[0]
	current_id = id
	var result: Variant = mod.call("handle", entry[1], params)
	_inflight -= 1
	current_id = -1
	if typeof(result) != TYPE_DICTIONARY:
		respond(id, err("Модуль %s вернул некорректный результат" % mod.get_script().resource_path, "internal"))
		return
	if result.get("deferred", false):
		return
	if result.has("error"):
		respond(id, err(str(result["error"]), str(result.get("code", "error"))))
		return
	# Модули могут возвращать как {data: ...}, так и «сырую» полезную нагрузку.
	respond(id, ok(result["data"] if result.has("data") else result))


func _run_deferred() -> void:
	if _deferred.is_empty():
		return
	var batch := _deferred
	_deferred = []
	for item: Dictionary in batch:
		var fn: Callable = item["fn"]
		if fn.is_valid():
			fn.call()


## Откладывает ответ до начала следующего кадра (нужно для снимков экрана и операций после _ready).
func defer_response(id: int, fn: Callable) -> void:
	_deferred.append({"id": id, "fn": fn})


func respond(id: int, payload: Dictionary) -> void:
	# ok выводится из наличия "error": ok() кладёт только data, err() — только error/code.
	var msg := {"type": "res", "id": id, "ok": not payload.has("error")}
	if payload.has("data"):
		msg["data"] = payload["data"]
	if payload.has("error"):
		msg["error"] = payload["error"]
	if payload.has("code"):
		msg["code"] = payload["code"]
	_send(msg)


func send_event(event: String, data: Variant = null) -> void:
	_send({"type": "event", "event": event, "data": data})


func _send(msg: Dictionary) -> void:
	if _peer == null or _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var text := JSON.stringify(msg)
	if text.length() > MAX_MESSAGE_BYTES:
		msg = {
			"type": "res" if msg.has("id") else "event",
			"id": msg.get("id", -1),
			"ok": false,
			"error": "Ответ превышает лимит %d байт (%d). Уменьшите объём запроса (max_nodes, props, limit)." % [MAX_MESSAGE_BYTES, text.length()],
			"code": "response_too_large",
		}
		if msg.get("type") == "event":
			msg["event"] = msg.get("event", "unknown")
		text = JSON.stringify(msg)
	var err := _peer.put_data((text + "\n").to_utf8_buffer())
	if err != OK:
		_drop_connection("write error %d" % err)


# --- результаты ---------------------------------------------------------------

func ok(data: Variant = null) -> Dictionary:
	return {"data": data}


func err(message: String, code: String = "error") -> Dictionary:
	_last_error = message
	return {"error": message, "code": code}


# --- метрики / шаги -----------------------------------------------------------

func _tick_metrics() -> void:
	_fps_sample_frames += 1
	var now := Time.get_ticks_msec()
	if now - _fps_sample_ms >= 1000:
		_fps = float(_fps_sample_frames) * 1000.0 / max(1, now - _fps_sample_ms)
		_fps_sample_frames = 0
		_fps_sample_ms = now


func _tick_step() -> void:
	if _step_budget > 0:
		var elapsed := Engine.get_process_frames() - _step_started_frame
		if elapsed >= _step_budget:
			_step_budget = 0
			_finish_step()


func _finish_step() -> void:
	var frames := Engine.get_process_frames() - _step_started_frame
	var elapsed := Time.get_ticks_msec() - _step_started_ms
	if _runtime_paused_by_step:
		paused = _user_paused
		_runtime_paused_by_step = false
	Engine.max_fps = _max_fps
	var id := _step_id
	_step_id = -1
	send_event("step_complete", {
		"request_id": id,
		"frames": frames,
		"elapsed_ms": elapsed,
		"status": runtime_status(),
	})


func start_step(id: int, frames: int) -> void:
	if _user_paused:
		_runtime_paused_by_step = true
	paused = false
	_step_id = id
	_step_budget = maxi(1, frames)
	_step_started_frame = Engine.get_process_frames()
	_step_started_ms = Time.get_ticks_msec()
	Engine.max_fps = DEFAULT_STEP_FPS


func set_max_fps(fps: int) -> void:
	_max_fps = clampi(fps, 0, 1000)
	Engine.max_fps = _max_fps


func get_max_fps() -> int:
	return _max_fps


func set_user_paused(value: bool) -> void:
	_user_paused = value
	if _step_budget <= 0:
		paused = value


func is_stepping() -> bool:
	return _step_budget > 0


# --- рантайм ------------------------------------------------------------------

func set_runtime_root(node: Node, scene_path: String) -> void:
	_runtime_root = node
	_runtime_scene = scene_path
	_runtime_started_at = Time.get_ticks_msec()
	current_scene = node


func get_runtime_root() -> Node:
	if _runtime_root != null and is_instance_valid(_runtime_root):
		return _runtime_root
	return null


func clear_runtime_root() -> void:
	_runtime_root = null
	_runtime_scene = ""
	_step_budget = 0
	_step_id = -1
	_user_paused = false
	paused = false
	Engine.max_fps = _max_fps


func runtime_status() -> Dictionary:
	var live := get_runtime_root() != null
	var d := {
		"running": live,
		"scene": _runtime_scene if live else "",
		"uptime_ms": (Time.get_ticks_msec() - _runtime_started_at) if live else 0,
		"paused": paused,
		"user_paused": _user_paused,
		"stepping": is_stepping(),
		"fps": snappedf(_fps, 0.1),
		"max_fps": _max_fps,
		"frame": Engine.get_process_frames(),
		"physics_frame": Engine.get_physics_frames(),
		"time_scale": Engine.time_scale,
		"fixed_fps": Engine.physics_ticks_per_second,
		"headless": DisplayServer.get_name() == "headless",
		"physics_2d_objects": PhysicsServer2D.get_process_info(PhysicsServer2D.INFO_ACTIVE_OBJECTS),
		"physics_3d_objects": PhysicsServer3D.get_process_info(PhysicsServer3D.INFO_ACTIVE_OBJECTS),
		"orphan_nodes": Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"memory_mb": snappedf(float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0, 0.1),
	}
	if live:
		d["root_children"] = _runtime_root.get_child_count()
	return d


# --- работа с деревом ---------------------------------------------------------

## Ищет узел от базового узла. Поддерживает абсолютные пути от /root,
## относительные пути, "%Unique" и сегменты вида "Name:2" (индекс среди одноимённых).
func find_node(base: Node, path: String) -> Node:
	if base == null:
		return null
	var p := path.strip_edges()
	if p == "" or p == "." or p == "/":
		return base
	if p.begins_with("/root"):
		base = root
		p = p.substr(5)
		if p == "":
			return base
	var cur: Node = base
	for seg: String in p.split("/", false):
		if seg == ".":
			continue
		if seg == "..":
			if cur.get_parent() != null:
				cur = cur.get_parent()
			continue
		cur = _find_child(cur, seg)
		if cur == null:
			return null
	return cur


func _find_child(parent: Node, seg: String) -> Node:
	if seg.begins_with("%"):
		return parent.get_node_or_null(NodePath(seg))
	var name_part := seg
	var idx := -1
	var colon := seg.rfind(":")
	if colon > 0 and seg.substr(colon + 1).is_valid_int():
		name_part = seg.substr(0, colon)
		idx = seg.substr(colon + 1).to_int()
	if name_part.is_empty():
		if idx >= 0 and idx < parent.get_child_count():
			return parent.get_child(idx)
		return null
	if idx < 0:
		if not name_part.is_valid_identifier():
			return null
		return parent.get_node_or_null(NodePath(name_part))
	var seen := 0
	for child: Node in parent.get_children():
		if str(child.name) == name_part:
			if seen == idx:
				return child
			seen += 1
	return null


## База поиска для рантайм-команд: текущая сцена, иначе корень окна.
func runtime_base() -> Node:
	var r := get_runtime_root()
	return r if r != null else root


func describe_node(node: Node) -> Dictionary:
	if node == null:
		return {}
	var d := {
		"name": str(node.name),
		"type": node.get_class(),
		"path": str(node.get_path()) if node.is_inside_tree() else "",
	}
	if node.owner != null:
		d["owner"] = str(node.owner.get_path()) if node.owner.is_inside_tree() else str(node.owner.name)
	if node.scene_file_path != "":
		d["instance"] = node.scene_file_path
	var groups := node.get_groups()
	if not groups.is_empty():
		d["groups"] = groups
	var scr := node.get_script()
	if scr != null:
		d["script"] = scr.resource_path
		if scr is Script and (scr as Script).get_global_name() != StringName():
			d["script_class"] = str((scr as Script).get_global_name())
	if node.get_parent() != null and node.owner == null and node.get_parent().owner != null:
		d["ownerless"] = true
	return d


# --- свойства -----------------------------------------------------------------

## Метаданные свойства экземпляра (type/hint/usage), без создания новых объектов.
func property_info(object: Object, prop: String) -> Dictionary:
	for p: Dictionary in object.get_property_list():
		if str(p["name"]) == prop:
			return p
	return {}


func class_has_property(cls: String, prop: String) -> bool:
	for p: Dictionary in ClassDB.class_get_property_list(cls, false):
		if str(p["name"]) == prop:
			return true
	return false


func class_default_value(cls: String, prop: String) -> Variant:
	if not ClassDB.class_exists(cls):
		return null
	var key := cls + "|" + prop
	if _prop_defaults.has(key):
		return _prop_defaults[key]
	var value: Variant = null
	if class_has_property(cls, prop):
		value = ClassDB.class_get_property_default_value(cls, prop)
	_prop_defaults[key] = value
	return value


func usage_flags(usage: int) -> Array:
	var out := []
	if usage & PROPERTY_USAGE_STORAGE:
		out.append("storage")
	if usage & PROPERTY_USAGE_EDITOR:
		out.append("editor")
	if usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
		out.append("script_variable")
	if usage & PROPERTY_USAGE_GROUP:
		out.append("group")
	if usage & PROPERTY_USAGE_CATEGORY:
		out.append("category")
	if usage & PROPERTY_USAGE_SUBGROUP:
		out.append("subgroup")
	if usage & PROPERTY_USAGE_CLASS_IS_BITFIELD:
		out.append("bitfield")
	if usage & PROPERTY_USAGE_CLASS_IS_ENUM:
		out.append("enum")
	if usage & PROPERTY_USAGE_INTERNAL:
		out.append("internal")
	if usage & PROPERTY_USAGE_NO_INSTANCE_STATE:
		out.append("no_instance_state")
	if usage & PROPERTY_USAGE_SCRIPT_DEFAULT_VALUE:
		out.append("script_default")
	if usage & PROPERTY_USAGE_RESTART_IF_CHANGED:
		out.append("restart_if_changed")
	return out


## Собирает свойства объекта. mode: saved | all | custom | changed
func collect_properties(object: Object, mode: String = "saved", names: Array = [], limit: int = 256) -> Dictionary:
	var out := {}
	var count := 0
	var truncated := false
	for p: Dictionary in object.get_property_list():
		var name := str(p["name"])
		if name.begins_with("script") and name != "script":
			continue
		var usage := int(p.get("usage", 0))
		var is_saved := (usage & PROPERTY_USAGE_STORAGE) != 0
		var is_editor := (usage & PROPERTY_USAGE_EDITOR) != 0
		var is_script := (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) != 0
		var wanted := false
		match mode:
			"all":
				wanted = is_editor or is_script
			"saved":
				wanted = is_saved or is_script
			"changed":
				wanted = is_saved or is_script
			_:
				wanted = is_saved or is_script
		if not names.is_empty():
			wanted = names.has(name)
		elif mode == "custom":
			wanted = is_editor or is_script
		if not wanted:
			continue
		if count >= limit:
			truncated = true
			break
		count += 1
		var value: Variant = object.get(name)
		var entry := {
			"value": V.encode(value),
			"type": type_string(int(p.get("type", 0))),
			"flags": usage_flags(usage),
		}
		if not is_script and ClassDB.class_exists(object.get_class()):
			var def: Variant = class_default_value(object.get_class(), name)
			if typeof(value) == typeof(def) and _same(value, def):
				entry["default"] = true
		if int(p.get("hint", 0)) != 0:
			entry["hint"] = str(type_string(int(p["hint"]))).trim_prefix("PROPERTY_HINT_").to_lower()
			if not str(p.get("hint_string", "")).is_empty():
				entry["hint_string"] = str(p["hint_string"])
		out[name] = entry
	return {"properties": out, "truncated": truncated, "count": count}


func _same(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Array or a is Dictionary or a is PackedByteArray:
		return str(V.encode(a)) == str(V.encode(b))
	return a == b


# --- вспомогательное ----------------------------------------------------------

func project_root() -> String:
	return ProjectSettings.globalize_path("res://")


func safe_res_path(path: String) -> String:
	if path.begins_with("res://") or path.begins_with("user://"):
		return path
	return "res://" + path.trim_prefix("/")


func display_name() -> String:
	return DisplayServer.get_name()

@warning_ignore_restore("inference_on_variant")
