
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Рантайм: запуск сцены в дереве хоста, покадровое выполнение, интроспекция, ввод.

const V := preload("res://.mcp/variant.gd")

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args
var _pending_request_id := -1


func commands() -> PackedStringArray:
	return PackedStringArray([
		"runtime.start",
		"runtime.stop",
		"runtime.status",
		"runtime.step",
		"runtime.pause",
		"runtime.tree",
		"runtime.inspect",
		"runtime.find",
		"runtime.get",
		"runtime.set",
		"runtime.call",
		"runtime.emit",
		"runtime.connect",
		"runtime.input",
	])


func _require_runtime() -> Dictionary:
	if host.get_runtime_root() == null:
		return {"error": "Игра не запущена. Вызовите runtime.start (godot_run).", "code": "no_runtime"}
	return {}


# --- запуск / остановка --------------------------------------------------------

func _start(p: Dictionary) -> Dictionary:
	if host.get_runtime_root() != null and not bool(p.get("restart", false)):
		return host.ok({"status": "already_running", "runtime": host.runtime_status()})
	if host.get_runtime_root() != null:
		_stop_instance()
	var scene_path := str(p.get("scene", ""))
	if scene_path.is_empty():
		scene_path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
		if scene_path.is_empty():
			return host.err("В настройках проекта не задан application/run/main_scene и не передан параметр scene", "bad_params")
	var res_path: String = host.safe_res_path(scene_path)
	if not ResourceLoader.exists(res_path):
		return host.err("Сцена не найдена: %s. Возможно, проект не импортирован (godot_project_import)." % res_path, "not_found")
	var res: Resource = ResourceLoader.load(res_path)
	if not (res is PackedScene):
		return host.err("Файл не является сценой: %s" % res_path, "wrong_type")
	var inst: Node = (res as PackedScene).instantiate()
	if inst == null:
		return host.err("Не удалось инстанцировать сцену %s" % res_path, "instantiate_error")
	if p.has("rename_root"):
		inst.name = str(p["rename_root"])
	host.root.add_child(inst)
	host.set_runtime_root(inst, res_path)
	host.set_user_paused(false)
	host.set_max_fps(int(p.get("max_fps", host.get_max_fps())))
	if p.has("time_scale"):
		Engine.time_scale = float(p["time_scale"])
	if p.has("fixed_fps"):
		Engine.physics_ticks_per_second = int(p["fixed_fps"])
	host.send_event("runtime_started", {"scene": res_path, "root": str(inst.get_path())})
	return host.ok({
		"status": "started",
		"scene": res_path,
		"root": str(inst.get_path()),
		"root_type": inst.get_class(),
		"runtime": host.runtime_status(),
	})


func _stop_instance() -> void:
	var rt: Node = host.get_runtime_root()
	if rt == null:
		return
	host.clear_runtime_root()
	rt.get_parent().remove_child(rt)
	rt.queue_free()


func _stop(p: Dictionary) -> Dictionary:
	if host.get_runtime_root() == null:
		return host.ok({"status": "not_running"})
	_stop_instance()
	return host.ok({"status": "stopped", "runtime": host.runtime_status()})


func _status(_p: Dictionary) -> Dictionary:
	return host.ok({"runtime": host.runtime_status()})


func _step(p: Dictionary) -> Dictionary:
	var req := _require_runtime()
	if req.has("error"):
		return host.err(str(req["error"]), str(req["code"]))
	var frames := int(p.get("frames", 0))
	if frames <= 0 and p.has("seconds"):
		frames = maxi(1, int(round(float(p["seconds"]) * float(Engine.physics_ticks_per_second))))
	if frames <= 0:
		frames = 1
	if frames > 100000:
		return host.err("Слишком много кадров: %d (максимум 100000)" % frames, "bad_params")
	host.start_step(host.current_id, frames)
	return host.ok({"status": "stepping", "frames": frames, "runtime": host.runtime_status()})


func _pause(p: Dictionary) -> Dictionary:
	var req := _require_runtime()
	if req.has("error"):
		return host.err(str(req["error"]), str(req["code"]))
	host.set_user_paused(bool(p.get("paused", true)))
	if p.has("time_scale"):
		Engine.time_scale = float(p["time_scale"])
	if p.has("max_fps"):
		host.set_max_fps(int(p["max_fps"]))
	return host.ok({"runtime": host.runtime_status()})


# --- интроспекция -------------------------------------------------------------

func _tree(p: Dictionary) -> Dictionary:
	var req := _require_runtime()
	if req.has("error"):
		return host.err(str(req["error"]), str(req["code"]))
	var node_path := str(p.get("node", ""))
	var base: Node = host.get_runtime_root()
	if not node_path.is_empty():
		base = host.find_node(base, node_path)
		if base == null:
			return host.err("Узел не найден: %s" % node_path, "node_not_found")
	var max_depth := int(p.get("max_depth", 0))
	var max_nodes := int(p.get("max_nodes", 400))
	var props_mode := str(p.get("props", "none"))
	var prop_names: Array = p.get("prop_names", [])
	var ctx := {
		"max_depth": max_depth,
		"max_nodes": max_nodes,
		"props_mode": props_mode,
		"prop_names": prop_names,
		"prop_limit": int(p.get("prop_limit", 24)),
		"count": 0,
		"truncated": false,
		"base_path": str(base.get_path()),
		"flat": [],
	}
	var entry := _build(base, 0, ctx)
	return host.ok({
		"node": entry,
		"flat": ctx["flat"],
		"node_count": ctx["count"],
		"truncated": ctx["truncated"],
		"runtime": host.runtime_status(),
	})


func _build(node: Node, depth: int, ctx: Dictionary) -> Dictionary:
	var entry: Dictionary = host.describe_node(node)
	entry["depth"] = depth
	entry["children_count"] = node.get_child_count()
	if ctx["props_mode"] != "none":
		entry["properties"] = host.collect_properties(node, ctx["props_mode"], ctx["prop_names"], int(ctx["prop_limit"]))["properties"]
	ctx["count"] = int(ctx["count"]) + 1
	ctx["flat"].append({
		"path": str(node.get_path()).trim_prefix(str(ctx["base_path"])),
		"type": node.get_class(),
		"name": str(node.name),
	})
	if int(ctx["max_depth"]) > 0 and depth >= int(ctx["max_depth"]):
		return entry
	if int(ctx["count"]) >= int(ctx["max_nodes"]):
		ctx["truncated"] = true
		return entry
	var children := []
	for child: Node in node.get_children():
		children.append(_build(child, depth + 1, ctx))
	if not children.is_empty():
		entry["children"] = children
	return entry


func _resolve(p: Dictionary) -> Dictionary:
	var node_path := str(p.get("node", ""))
	if node_path.is_empty():
		return {"error": "Не указан параметр node", "code": "bad_params"}
	var base: Node = host.runtime_base()
	var node: Node = host.find_node(base, node_path)
	if node == null:
		return {"error": "Узел не найден: %s" % node_path, "code": "node_not_found"}
	return {"node": node}


func _inspect(p: Dictionary) -> Dictionary:
	var req := _require_runtime()
	if req.has("error"):
		return host.err(str(req["error"]), str(req["code"]))
	var resolved := _resolve(p)
	if resolved.has("error"):
		return host.err(str(resolved["error"]), str(resolved["code"]))
	var node: Node = resolved["node"]
	var out: Dictionary = host.describe_node(node)
	out["properties"] = host.collect_properties(node, str(p.get("mode", "saved")), p.get("props", []), int(p.get("limit", 200)))
	var signals := []
	for s: Dictionary in node.get_signal_list():
		signals.append(str(s.get("name", "")))
	out["signals"] = signals
	var filt := str(p.get("method_filter", ""))
	if not filt.is_empty():
		var methods := []
		for m: Dictionary in node.get_method_list():
			if str(m.get("name", "")).contains(filt):
				var arg_names := []
				for a: Dictionary in m.get("args", []):
					arg_names.append(str(a.get("name", "")))
				methods.append({"name": str(m["name"]), "args": arg_names})
		out["methods"] = methods
	out["group_counts"] = _group_counts(node)
	return host.ok(out)


func _group_counts(node: Node) -> Dictionary:
	var out := {}
	for g: String in node.get_groups():
		out[g] = node.get_tree().get_nodes_in_group(g).size()
	return out


## Поиск узлов по имени, типу, группе, классу или наличию скрипта.
func _find(p: Dictionary) -> Dictionary:
	var req := _require_runtime()
	if req.has("error"):
		return host.err(str(req["error"]), str(req["code"]))
	var limit := int(p.get("limit", 50))
	var name := str(p.get("name", ""))
	var type_name := str(p.get("type", ""))
	var group := str(p.get("group", ""))
	var script_path := str(p.get("script", ""))
	var with_script := bool(p.get("has_script", false))
	var base: Node = host.runtime_base()
	var root_rel := str(base.get_path())
	var found := []
	var stack := [base]
	var scanned := 0
	while not stack.is_empty() and found.size() < limit:
		var node: Node = stack.pop_front()
		scanned += 1
		var ok := true
		if not name.is_empty() and not str(node.name).contains(name):
			ok = false
		if ok and not type_name.is_empty() and not ClassDB.is_parent_class(node.get_class(), type_name):
			ok = false
		if ok and not group.is_empty() and not node.is_in_group(group):
			ok = false
		if ok and not script_path.is_empty():
			var s := node.get_script()
			ok = s != null and s.resource_path == host.safe_res_path(script_path)
		if ok and with_script and node.get_script() == null:
			ok = false
		if ok:
			var entry: Dictionary = host.describe_node(node)
			entry["relative_path"] = str(node.get_path()).trim_prefix(root_rel)
			found.append(entry)
		for child: Node in node.get_children():
			stack.append(child)
	return host.ok({"nodes": found, "scanned": scanned, "truncated": found.size() >= limit, "base": root_rel})


func _read_prop(p: Dictionary) -> Dictionary:
	var resolved := _resolve(p)
	if resolved.has("error"):
		return host.err(str(resolved["error"]), str(resolved["code"]))
	var node: Node = resolved["node"]
	var key := str(p.get("property", ""))
	if key.is_empty():
		return host.err("Не указан параметр property", "bad_params")
	var value: Variant = node.get_indexed(NodePath(key))
	if value == null and not _has_indexed(node, key):
		return host.err(fmt("Свойство не найдено: %s (%s)", [key, node.get_class()]), "property_not_found")
	return host.ok({"node": str(node.get_path()), "property": key, "value": V.encode(value)})


func _has_indexed(node: Object, key: String) -> bool:
	var pieces := key.split("/", false)
	var leaf := pieces[pieces.size() - 1]
	return not host.property_info(node, leaf).is_empty()


func _write_props(p: Dictionary) -> Dictionary:
	var resolved := _resolve(p)
	if resolved.has("error"):
		return host.err(str(resolved["error"]), str(resolved["code"]))
	var node: Node = resolved["node"]
	var items: Array = p.get("items", [])
	if items.is_empty() and p.has("property"):
		items = [{"key": str(p["property"]), "value": p.get("value", null)}]
	var applied := []
	for item: Variant in items:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = item
		var key := str(entry.get("key", ""))
		if key.is_empty():
			continue
		var pieces := key.split("/", false)
		var leaf := pieces[pieces.size() - 1]
		var target: Object = node
		if pieces.size() > 1:
			target = node.get_indexed(NodePath("/".join(pieces.slice(0, pieces.size() - 1))))
			if target == null:
				return host.err("Вложенный объект не найден для %s" % key, "property_not_found")
		var info: Dictionary = host.property_info(target, leaf)
		if info.is_empty():
			return host.err(fmt("Свойство не найдено: %s.%s", [target.get_class(), leaf]), "property_not_found")
		var value: Variant = V.coerce(entry.get("value", null), int(info.get("type", 0)))
		target.set(leaf, value)
		applied.append({"property": key, "value": V.encode(value)})
	return host.ok({"node": str(node.get_path()), "applied": applied})


func _call(p: Dictionary) -> Dictionary:
	var resolved := _resolve(p)
	if resolved.has("error"):
		return host.err(str(resolved["error"]), str(resolved["code"]))
	var node: Node = resolved["node"]
	var method := str(p.get("method", ""))
	if method.is_empty():
		return host.err("Не указан параметр method", "bad_params")
	if not node.has_method(method):
		return host.err(fmt("У узла %s (%s) нет метода %s", [node.get_class(), str(node.name), method]), "method_not_found")
	var args := []
	for a: Variant in p.get("args", []):
		args.append(V.coerce(a, TYPE_NIL))
	var result: Variant = node.callv(method, args)
	return host.ok({
		"node": str(node.get_path()),
		"method": method,
		"result": V.encode(result),
	})


func _emit(p: Dictionary) -> Dictionary:
	var resolved := _resolve(p)
	if resolved.has("error"):
		return host.err(str(resolved["error"]), str(resolved["code"]))
	var node: Node = resolved["node"]
	var sig := str(p.get("signal", ""))
	if not node.has_signal(sig):
		return host.err(fmt("У узла %s нет сигнала %s", [node.get_class(), sig]), "signal_not_found")
	var args := []
	for a: Variant in p.get("args", []):
		args.append(V.coerce(a, TYPE_NIL))
	var full_args := [sig]
	full_args.append_array(args)
	node.callv("emit_signal", full_args)
	return host.ok({"node": str(node.get_path()), "signal": sig, "args": args.size()})


func _connect(p: Dictionary) -> Dictionary:
	var from_resolved := _resolve({"node": str(p.get("from", ""))})
	var to_node: Node = host.find_node(host.runtime_base(), str(p.get("to", "")))
	if from_resolved.has("error") or to_node == null:
		return host.err("Не найдены узлы from/to", "node_not_found")
	var from_node: Node = from_resolved["node"]
	var sig := str(p.get("signal", ""))
	var method := str(p.get("method", ""))
	if not from_node.has_signal(sig):
		return host.err("Нет сигнала %s" % sig, "signal_not_found")
	if not to_node.has_method(method):
		return host.err("Нет метода %s" % method, "method_not_found")
	if bool(p.get("disconnect", false)):
		if from_node.is_connected(sig, Callable(to_node, method)):
			from_node.disconnect(sig, Callable(to_node, method))
		return host.ok({"disconnected": true})
	var flags := int(p.get("flags", 0))
	var cb := Callable(to_node, method)
	var err := from_node.connect(sig, cb, flags)
	if err != OK:
		return host.err("connect() вернул %s" % error_string(err), "connect_error")
	return host.ok({"connected": true, "from": str(from_node.get_path()), "to": str(to_node.get_path()), "signal": sig, "method": method})


# --- ввод ---------------------------------------------------------------------

func _input(p: Dictionary) -> Dictionary:
	var req := _require_runtime()
	if req.has("error"):
		return host.err(str(req["error"]), str(req["code"]))
	var mode := str(p.get("mode", "action"))
	match mode:
		"action":
			var action := str(p.get("action", ""))
			if not InputMap.has_action(action):
				return host.err("Действие отсутствует в InputMap: %s" % action, "not_found")
			if bool(p.get("pressed", true)):
				Input.action_press(action, float(p.get("strength", 1.0)))
			else:
				Input.action_release(action)
			return host.ok({"action": action, "pressed": bool(p.get("pressed", true))})
		"key":
			var ev := InputEventKey.new()
			ev.keycode = _keycode(str(p.get("key", "SPACE")))
			ev.physical_keycode = ev.keycode
			ev.pressed = bool(p.get("pressed", true))
			ev.echo = bool(p.get("echo", false))
			ev.shift_pressed = bool(p.get("shift", false))
			ev.ctrl_pressed = bool(p.get("ctrl", false))
			ev.alt_pressed = bool(p.get("alt", false))
			ev.meta_pressed = bool(p.get("meta", false))
			Input.parse_input_event(ev)
			return host.ok({"key": str(p.get("key", "")), "pressed": ev.pressed})
		"text":
			var tev := InputEventKey.new()
			tev.unicode = int(p.get("unicode", 0))
			tev.pressed = true
			Input.parse_input_event(tev)
			return host.ok({"unicode": tev.unicode})
		"mouse_button":
			var mev := InputEventMouseButton.new()
			mev.button_index = int(p.get("button", MOUSE_BUTTON_LEFT))
			mev.pressed = bool(p.get("pressed", true))
			mev.position = _vec2(p.get("position", null))
			mev.global_position = mev.position
			mev.button_mask = int(p.get("mask", 0))
			Input.parse_input_event(mev)
			return host.ok({"button": mev.button_index, "pressed": mev.pressed, "position": V.encode(mev.position)})
		"mouse_motion":
			var mm := InputEventMouseMotion.new()
			mm.position = _vec2(p.get("position", null))
			mm.relative = _vec2(p.get("relative", null))
			Input.parse_input_event(mm)
			return host.ok({"position": V.encode(mm.position), "relative": V.encode(mm.relative)})
		"joy_button":
			var jev := InputEventJoypadButton.new()
			jev.button_index = int(p.get("button", JOY_BUTTON_A))
			jev.pressed = bool(p.get("pressed", true))
			Input.parse_input_event(jev)
			return host.ok({"button": jev.button_index, "pressed": jev.pressed})
		"release_all":
			for action: String in InputMap.get_actions():
				if Input.is_action_pressed(action):
					Input.action_release(action)
			return host.ok({"released": true})
	return host.err("Неизвестный режим ввода: %s" % mode, "bad_params")


func _vec2(value: Variant) -> Vector2:
	if typeof(value) == TYPE_DICTIONARY and value.has("x"):
		return Vector2(float(value.get("x", 0)), float(value.get("y", 0)))
	if typeof(value) == TYPE_ARRAY and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO


func _keycode(name: String) -> Key:
	if name == "":
		return KEY_NONE
	var kc: Key = OS.find_keycode_from_string(name)
	return kc


func handle(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"runtime.start":
			return _start(p)
		"runtime.stop":
			return _stop(p)
		"runtime.status":
			return _status(p)
		"runtime.step":
			return _step(p)
		"runtime.pause":
			return _pause(p)
		"runtime.tree":
			return _tree(p)
		"runtime.inspect":
			return _inspect(p)
		"runtime.find":
			return _find(p)
		"runtime.get":
			return _read_prop(p)
		"runtime.set":
			return _write_props(p)
		"runtime.call":
			return _call(p)
		"runtime.emit":
			return _emit(p)
		"runtime.connect":
			return _connect(p)
		"runtime.input":
			return _input(p)
	return host.err("Команда не реализована в runtime: %s" % cmd, "not_implemented")

@warning_ignore_restore("inference_on_variant")
