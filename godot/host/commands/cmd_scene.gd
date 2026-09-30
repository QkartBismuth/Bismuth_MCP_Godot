
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Сцены: чтение дерева, инспекция узлов, создание и транзакционное редактирование.

const V := preload("res://.mcp/variant.gd")
const BACKUP_DIR := "res://.mcp-backups"

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args


func commands() -> PackedStringArray:
	return PackedStringArray([
		"scene.tree",
		"scene.state",
		"scene.inspect",
		"scene.create",
		"scene.apply_ops",
		"scene.backups",
		"scene.restore",
	])


# --- загрузка / сохранение ----------------------------------------------------

func _load_packed(path: String) -> Dictionary:
	var res_path: Variant = host.safe_res_path(path)
	if not ResourceLoader.exists(res_path):
		return {"error": "Сцена не найдена: %s" % res_path, "code": "not_found"}
	var res: Resource = ResourceLoader.load(res_path)
	if res == null or not (res is PackedScene):
		return {"error": "Файл не является PackedScene: %s" % res_path, "code": "wrong_type"}
	var packed: PackedScene = res
	var inst: Node = packed.instantiate()
	if inst == null:
		return {"error": "Не удалось инстанцировать сцену %s (проверьте _init и зависимости)" % res_path, "code": "instantiate_error"}
	return {"packed": packed, "root": inst, "path": res_path}


## Приводит владельцев к виду, который ожидает SceneState::pack():
## все узлы сцены принадлежат корню, а содержимое подсцен остаётся внутренним.
func _normalize_owners(node: Node, root: Node) -> void:
	for child: Node in node.get_children():
		child.owner = root
		if child.scene_file_path != "" and not node.is_editable_instance(child):
			continue
		_normalize_owners(child, root)


func _backup(path: String, keep: int) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	DirAccess.make_dir_recursive_absolute(BACKUP_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var name := BACKUP_DIR.path_join(fmt("%s_%s.bak", [stamp, path.get_file()]))
	var err := DirAccess.copy_absolute(path, name)
	if err != OK:
		return {}
	_prune_backups(path.get_file(), keep)
	return {"backup": ProjectSettings.globalize_path(name)}


func _prune_backups(file_name: String, keep: int) -> void:
	var da := DirAccess.open(BACKUP_DIR)
	if da == null:
		return
	var list := []
	da.list_dir_begin()
	var entry := da.get_next()
	while not entry.is_empty():
		if not da.current_is_dir() and entry.ends_with("_" + file_name):
			list.append(entry)
		entry = da.get_next()
	da.list_dir_end()
	if list.size() <= keep:
		return
	list.sort()
	for i: int in range(0, list.size() - keep):
		DirAccess.remove_absolute(BACKUP_DIR.path_join(list[i]))


func _save(packed: PackedScene, root: Node, path: String) -> Dictionary:
	_normalize_owners(root, root)
	var perr := packed.pack(root)
	if perr != OK:
		return {"error": "PackedScene.pack() вернул %s" % error_string(perr), "code": "pack_error"}
	var serr := ResourceSaver.save(packed, host.safe_res_path(path))
	if serr != OK:
		return {"error": fmt("ResourceSaver.save() вернул %s для %s", [error_string(serr), path]), "code": "save_error"}
	var uid := ResourceLoader.get_resource_uid(host.safe_res_path(path))
	return {
		"saved": true,
		"path": host.safe_res_path(path),
		"uid": ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else "",
		"nodes": _count(root),
	}


func _count(node: Node) -> int:
	var n := 1
	for child: Node in node.get_children():
		n += _count(child)
	return n


# --- scene.tree (живое дерево) ------------------------------------------------

func _tree(root: Node, p: Dictionary) -> Dictionary:
	var ctx := {
		"max_depth": int(p.get("max_depth", 0)),
		"max_nodes": int(p.get("max_nodes", 600)),
		"props_mode": str(p.get("props", "none")),
		"prop_names": p.get("prop_names", []),
		"prop_limit": int(p.get("prop_limit", 24)),
		"count": 0,
		"truncated": false,
		"base_path": str(root.get_path()),
		"flat": [],
	}
	var data := _build_entry(root, 0, ctx)
	return {
		"root": data,
		"flat": ctx["flat"],
		"node_count": ctx["count"],
		"truncated": ctx["truncated"],
	}


func _build_entry(node: Node, depth: int, ctx: Dictionary) -> Dictionary:
	var entry: Variant = host.describe_node(node)
	entry["depth"] = depth
	entry["children_count"] = node.get_child_count()
	if ctx["props_mode"] != "none":
		var collected: Dictionary = host.collect_properties(node, ctx["props_mode"], ctx["prop_names"], ctx["prop_limit"])
		entry["properties"] = collected["properties"]
	ctx["count"] = int(ctx["count"]) + 1
	if node.is_inside_tree():
		ctx["flat"].append({
			"path": str(node.get_path()).trim_prefix(str(ctx["base_path"])),
			"type": node.get_class(),
			"name": str(node.name),
		})
	if int(ctx["max_depth"]) > 0 and depth >= int(ctx["max_depth"]):
		if node.get_child_count() > 0:
			entry["children_truncated"] = true
		return entry
	if int(ctx["count"]) >= int(ctx["max_nodes"]):
		ctx["truncated"] = true
		if node.get_child_count() > 0:
			entry["children_truncated"] = true
		return entry
	var children := []
	for child: Node in node.get_children():
		children.append(_build_entry(child, depth + 1, ctx))
	if not children.is_empty():
		entry["children"] = children
	return entry


func _tree_cmd(p: Dictionary) -> Dictionary:
	var source := str(p.get("source", "file"))
	if source == "live":
		var rt: Variant = host.get_runtime_root()
		if rt == null:
			return host.err("Игра не запущена. Сначала вызовите godot_run.", "no_runtime")
		var out := _tree(rt, p)
		out["source"] = "live"
		return host.ok(out)
	var path := str(p.get("path", ""))
	if path.is_empty():
		path = str(ProjectSettings.get_setting("application/run/main_scene", ""))
		if path.is_empty():
			return host.err("Не указан параметр path и в настройках нет main_scene", "bad_params")
	var loaded := _load_packed(path)
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var res := _tree(loaded["root"], p)
	res["path"] = loaded["path"]
	loaded["root"].free()
	return host.ok(res)


# --- scene.state (статическое представление файла сцены) ----------------------

func _state(p: Dictionary) -> Dictionary:
	var path: Variant = host.safe_res_path(str(p.get("path", "")))
	if not ResourceLoader.exists(path):
		return host.err("Сцена не найдена: %s" % path, "not_found")
	var res: Resource = ResourceLoader.load(path)
	if not (res is PackedScene):
		return host.err("Файл не является PackedScene: %s" % path, "wrong_type")
	var state: SceneState = (res as PackedScene).get_state()
	if state == null:
		return host.err("Не удалось получить SceneState (импортируйте проект: godot_project_import)", "no_state")
	var want_props := bool(p.get("props", true))
	var nodes := []
	for i: int in range(state.get_node_count()):
		var entry := {
			"index": i,
			"name": state.get_node_name(i),
			"type": state.get_node_type(i),
			"path": state.get_node_path(i, false),
			"parent_path": state.get_node_path(i, true),
			"owner_path": state.get_node_owner_path(i),
			"placeholder": state.is_node_instance_placeholder(i),
		}
		var groups := state.get_node_groups(i)
		if not groups.is_empty():
			entry["groups"] = groups
		var inst := state.get_node_instance(i)
		if inst != null:
			entry["instance"] = inst.resource_path
		if want_props:
			var props := {}
			for pi: int in range(state.get_node_property_count(i)):
				props[state.get_node_property_name(i, pi)] = V.encode(state.get_node_property_value(i, pi))
			if not props.is_empty():
				entry["stored_properties"] = props
		nodes.append(entry)
	var connections := []
	for i: int in range(state.get_connection_count()):
		connections.append({
			"from": state.get_connection_source(i),
			"signal": state.get_connection_signal(i),
			"to": state.get_connection_target(i),
			"method": state.get_connection_method(i),
			"flags": state.get_connection_flags(i),
			"binds": state.get_connection_binds(i),
		})
	return {
		"path": path,
		"node_count": state.get_node_count(),
		"nodes": nodes,
		"connections": connections,
		"base_scene": state.get_base_scene_state() != null,
	}


# --- scene.inspect ------------------------------------------------------------

func _inspect(p: Dictionary) -> Dictionary:
	var base: Node = null
	var source := str(p.get("source", "file"))
	var loaded := {}
	var root_label := ""
	if source == "live":
		base = host.runtime_base()
		root_label = "live"
	else:
		loaded = _load_packed(str(p.get("path", "")))
		if loaded.has("error"):
			return host.err(str(loaded["error"]), str(loaded["code"]))
		base = loaded["root"]
		root_label = loaded["path"]
	var node_path := str(p.get("node", ""))
	var node: Node = base if node_path.is_empty() else host.find_node(base, node_path)
	if node == null:
		var msg := "Узел не найден: %s" % node_path
		if not loaded.is_empty():
			loaded["root"].free()
		return host.err(msg, "node_not_found")
	var out: Variant = host.describe_node(node)
	out["source"] = root_label
	out["properties"] = host.collect_properties(node, str(p.get("mode", "saved")), p.get("props", []), int(p.get("limit", 200)))
	var methods := []
	for m: Dictionary in node.get_method_list():
		var arg_names := []
		for a: Dictionary in m.get("args", []):
			arg_names.append(str(a.get("name", "")))
		methods.append({
			"name": str(m.get("name", "")),
			"args": arg_names,
		})
	if p.get("methods", true):
		var filt := str(p.get("method_filter", ""))
		if filt == "":
			out["methods"] = methods
		else:
			var filtered := []
			for m2: Dictionary in methods:
				if str(m2["name"]).contains(filt):
					filtered.append(m2)
			out["methods"] = filtered
	var signals := []
	var connected := []
	for s: Dictionary in node.get_signal_list():
		var sig_name := str(s.get("name", ""))
		signals.append(sig_name)
		for c: Dictionary in node.get_signal_connection_list(sig_name):
			var callable: Callable = c.get("callable", Callable())
			connected.append({
				"signal": sig_name,
				"target": str(callable.get_object().get_path()) if callable.get_object() != null else "",
				"method": str(callable.get_method()),
			})
	out["signals"] = signals
	if not connected.is_empty():
		out["connected_signals"] = connected
	if not loaded.is_empty():
		loaded["root"].free()
	return host.ok(out)


# --- scene.create -------------------------------------------------------------

func _create(p: Dictionary) -> Dictionary:
	var root_type := str(p.get("root_type", "Node2D"))
	if not ClassDB.class_exists(root_type) or not ClassDB.is_parent_class(root_type, "Node"):
		return host.err("Некорректный root_type: %s" % root_type, "bad_params")
	var root: Node = ClassDB.instantiate(root_type)
	root.name = str(p.get("root_name", root_type))
	var packed := PackedScene.new()
	var applied := _apply_ops(root, p.get("ops", []), true)
	if applied.has("error"):
		root.free()
		return host.err(str(applied["error"]), str(applied.get("code", "op_error")))
	# _apply_ops отдаёт лог операций, а _save — итог; объединяем явно.
	var path := str(p.get("path", ""))
	if path.is_empty():
		root.free()
		return host.err("Не указан параметр path", "bad_params")
	if FileAccess.file_exists(host.safe_res_path(path)) and not bool(p.get("overwrite", false)):
		root.free()
		return host.err("Файл уже существует: %s (передайте overwrite=true)" % path, "exists")
	var res_path: Variant = host.safe_res_path(path)
	DirAccess.make_dir_recursive_absolute(res_path.get_base_dir())
	if FileAccess.file_exists(res_path):
		var b := _backup(res_path, 5)
		if not b.is_empty():
			applied["backup"] = b["backup"]
	var saved := _save(packed, root, res_path)
	root.free()
	if saved.has("error"):
		return host.err(str(saved["error"]), str(saved["code"]))
	var out := {"ops": applied["applied"], "saved": false}
	out["backup"] = applied["backup"] if applied.has("backup") else ""
	for key: String in saved:
		out[key] = saved[key]
	return host.ok(out)


# --- scene.apply_ops ----------------------------------------------------------

func _apply_ops(root: Node, ops: Array, is_create: bool) -> Dictionary:
	var log := []
	for i: int in range(ops.size()):
		var item: Variant = ops[i]
		if typeof(item) != TYPE_DICTIONARY:
			log.append({"index": i, "op": "?", "status": "skipped", "reason": "ожидался объект"})
			continue
		var op: Dictionary = item
		var op_name := str(op.get("op", ""))
		var outcome := _apply_one(root, op, is_create)
		outcome["index"] = i
		outcome["op"] = op_name
		log.append(outcome)
		if outcome.get("status") == "error":
			return {"error": fmt("Операция #%d (%s) провалилась: %s", [i, op_name, outcome.get("error", "?")]), "code": "op_failed", "log": log}
	return {"applied": log}


func _base_for(root: Node, op: Dictionary) -> Node:
	var target_path := str(op.get("path", ""))
	if target_path.is_empty():
		return root
	return host.find_node(root, target_path)


func _apply_one(root: Node, op: Dictionary, is_create: bool) -> Dictionary:
	var name := str(op.get("op", ""))
	match name:
		"add_node":
			var parent_path := str(op.get("parent", ""))
			var parent: Node = root if parent_path.is_empty() else host.find_node(root, parent_path)
			if parent == null:
				return {"status": "error", "error": "родитель не найден: %s" % parent_path}
			var type_name := str(op.get("type", "Node"))
			if not ClassDB.class_exists(type_name) or not ClassDB.is_parent_class(type_name, "Node"):
				return {"status": "error", "error": "неизвестный тип узла: %s" % type_name}
			var node: Node = ClassDB.instantiate(type_name)
			var node_name := str(op.get("name", type_name))
			if not node_name.is_empty() and node_name != type_name:
				node.name = node_name
			parent.add_child(node, true)
			node.owner = root
			var extra := {"node": str(node.name), "type": type_name}
			if op.has("props"):
				var setr: Dictionary = _set_props(node, op["props"])
				if setr.has("error"):
					return {"status": "error", "error": str(setr["error"]), "node": str(node.name)}
				extra["properties"] = setr["applied"]
			if op.has("script"):
				var scr: Resource = ResourceLoader.load(host.safe_res_path(str(op["script"])))
				if scr == null:
					return {"status": "error", "error": "скрипт не найден: %s" % op["script"]}
				node.set_script(scr)
				extra["script"] = str(op["script"])
			for g: Variant in op.get("groups", []):
				node.add_to_group(str(g))
			if op.has("index"):
				var idx := int(op["index"])
				var cur := node.get_index()
				if idx != cur and idx >= 0:
					parent.move_child(node, idx)
			elif op.has("after"):
				var sibling: Node = host.find_node(root, str(op["after"]))
				if sibling != null and sibling.get_parent() == parent:
					parent.move_child(node, sibling.get_index() + 1)
			return {"status": "ok", "detail": extra}
		"instantiate_scene":
			var parent_path2 := str(op.get("parent", ""))
			var parent2: Node = root if parent_path2.is_empty() else host.find_node(root, parent_path2)
			if parent2 == null:
				return {"status": "error", "error": "родитель не найден: %s" % parent_path2}
			var scene_path: Variant = host.safe_res_path(str(op.get("scene", "")))
			if not ResourceLoader.exists(scene_path):
				return {"status": "error", "error": "сцена не найдена: %s" % scene_path}
			var packed: PackedScene = ResourceLoader.load(scene_path)
			var inst: Node = packed.instantiate()
			inst.name = str(op.get("name", inst.name))
			parent2.add_child(inst, true)
			inst.owner = root
			if op.has("props"):
				var setr2: Dictionary = _set_props(inst, op["props"])
				if setr2.has("error"):
					return {"status": "error", "error": str(setr2["error"])}
			return {"status": "ok", "detail": {"node": str(inst.name), "scene": scene_path}}
		"remove_node":
			var node2: Node = _base_for(root, op)
			if node2 == null:
				return {"status": "error", "error": "узел не найден: %s" % str(op.get("path", ""))}
			if node2 == root:
				return {"status": "error", "error": "нельзя удалить корень сцены"}
			var label := str(node2.get_path())
			var parent3 := node2.get_parent()
			parent3.remove_child(node2)
			node2.queue_free()
			return {"status": "ok", "detail": {"removed": label}}
		"duplicate":
			var node3: Node = _base_for(root, op)
			if node3 == null:
				return {"status": "error", "error": "узел не найден: %s" % str(op.get("path", ""))}
			var copy: Node = node3.duplicate(int(p_flags(op)))
			if copy == null:
				return {"status": "error", "error": "duplicate() вернул null"}
			if op.has("name"):
				copy.name = str(op["name"])
			node3.get_parent().add_child(copy, true)
			copy.owner = root
			return {"status": "ok", "detail": {"node": str(copy.name)}}
		"rename":
			var node4: Node = _base_for(root, op)
			if node4 == null:
				return {"status": "error", "error": "узел не найден"}
			var old := str(node4.name)
			var new_name := str(op.get("name", ""))
			if new_name.is_empty() or not new_name.is_valid_identifier():
				return {"status": "error", "error": "некорректное имя узла: %s" % new_name}
			node4.name = new_name
			return {"status": "ok", "detail": {"from": old, "to": new_name}}
		"reparent":
			var node5: Node = _base_for(root, op)
			if node5 == null:
				return {"status": "error", "error": "узел не найден"}
			var target: Variant = host.find_node(root, str(op.get("new_parent", "")))
			if target == null:
				return {"status": "error", "error": "новый родитель не найден: %s" % str(op.get("new_parent", ""))}
			if node5 == root:
				return {"status": "error", "error": "нельзя переместить корень сцены"}
			if node5.is_ancestor_of(target) or target.is_ancestor_of(node5):
				return {"status": "error", "error": "перемещение создаст цикл в дереве"}
			var keep_transform := bool(op.get("keep_transform", true))
			var global_xf: Variant = null
			if node5 is Node2D:
				global_xf = (node5 as Node2D).global_transform
			elif node5 is Control:
				global_xf = (node5 as Control).global_position
			node5.get_parent().remove_child(node5)
			target.add_child(node5)
			_normalize_owners(node5, root)
			node5.owner = root
			if keep_transform and global_xf != null:
				if node5 is Node2D:
					(node5 as Node2D).global_transform = global_xf
				elif node5 is Control:
					(node5 as Control).global_position = global_xf
			if op.has("index"):
				target.move_child(node5, int(op["index"]))
			return {"status": "ok", "detail": {"node": str(node5.name), "new_parent": str(target.get_path())}}
		"move":
			var node6: Node = _base_for(root, op)
			if node6 == null or node6.get_parent() == null:
				return {"status": "error", "error": "узел не найден"}
			var idx2 := int(op.get("index", node6.get_index()))
			node6.get_parent().move_child(node6, clampi(idx2, 0, node6.get_parent().get_child_count() - 1))
			return {"status": "ok", "detail": {"node": str(node6.name), "index": node6.get_index()}}
		"set_props":
			var node7: Node = _base_for(root, op)
			if node7 == null:
				return {"status": "error", "error": "узел не найден"}
			var setr3: Dictionary = _set_props(node7, op.get("props", {}))
			if setr3.has("error"):
				return {"status": "error", "error": str(setr3["error"])}
			return {"status": "ok", "detail": {"node": str(node7.name), "applied": setr3["applied"]}}
		"group":
			var node8: Node = _base_for(root, op)
			if node8 == null:
				return {"status": "error", "error": "узел не найден"}
			for g2: Variant in op.get("add", []):
				node8.add_to_group(str(g2))
			for g3: Variant in op.get("remove", []):
				node8.remove_from_group(str(g3))
			return {"status": "ok", "detail": {"node": str(node8.name), "groups": node8.get_groups()}}
		"script":
			var node9: Node = _base_for(root, op)
			if node9 == null:
				return {"status": "error", "error": "узел не найден"}
			if bool(op.get("detach", false)):
				node9.set_script(null)
				return {"status": "ok", "detail": {"node": str(node9.name), "script": null}}
			var script_res: Resource = ResourceLoader.load(host.safe_res_path(str(op.get("attach", ""))))
			if script_res == null:
				return {"status": "error", "error": "скрипт не найден"}
			node9.set_script(script_res)
			if op.has("props"):
				var setr4: Dictionary = _set_props(node9, op["props"])
				if setr4.has("error"):
					return {"status": "error", "error": str(setr4["error"])}
			return {"status": "ok", "detail": {"node": str(node9.name), "script": str(script_res.resource_path)}}
		"connect":
			var from: Node = _base_for(root, op)
			var to_name := str(op.get("to", ""))
			var to_node: Node = host.find_node(root, to_name)
			if from == null or to_node == null:
				var from_label := str(op.get("from", op.get("path", "")))
				return {"status": "error", "error": fmt("не найден узел: from=%s, to=%s", [from_label, to_name])}
			var sig := str(op.get("signal", ""))
			if not from.has_signal(sig):
				return {"status": "error", "error": fmt("у узла %s нет сигнала %s", [from.get_class(), sig])}
			var target_method := str(op.get("method", ""))
			if not to_node.has_method(target_method):
				return {"status": "error", "error": fmt("у узла %s нет метода %s", [to_node.get_class(), target_method])}
			var binds: Array = []
			for b: Variant in op.get("binds", []):
				binds.append(V.coerce(b, TYPE_NIL))
			var flags := int(op.get("flags", CONNECT_PERSIST))
			if from.is_connected(sig, Callable(to_node, target_method)):
				from.disconnect(sig, Callable(to_node, target_method))
			var cerr := from.connect(sig, Callable(to_node, target_method), flags)
			if cerr != OK:
				return {"status": "error", "error": "connect() вернул %s" % error_string(cerr)}
			return {"status": "ok", "detail": {"from": str(from.get_path()), "signal": sig, "to": str(target_method)}}
		"disconnect":
			var from2: Node = _base_for(root, op)
			var to2: Node = host.find_node(root, str(op.get("to", "")))
			if from2 == null or to2 == null:
				return {"status": "error", "error": "узел не найден"}
			var sig2 := str(op.get("signal", ""))
			var method2 := str(op.get("method", ""))
			if from2.is_connected(sig2, Callable(to2, method2)):
				from2.disconnect(sig2, Callable(to2, method2))
				return {"status": "ok", "detail": {"disconnected": true}}
			return {"status": "error", "error": "соединение не найдено"}
		"set_owner":
			var node10: Node = _base_for(root, op)
			var owner_node: Node = host.find_node(root, str(op.get("owner", ""))) if not str(op.get("owner", "")).is_empty() else null
			if node10 == null:
				return {"status": "error", "error": "узел не найден"}
			node10.owner = owner_node
			for child: Node in node10.get_children():
				child.owner = owner_node
			return {"status": "ok", "detail": {"node": str(node10.name), "owner": str(owner_node.get_path()) if owner_node else null}}
		"set_meta":
			var node11: Node = _base_for(root, op)
			if node11 == null:
				return {"status": "error", "error": "узел не найден"}
			node11.set_meta(str(op.get("key", "")), V.coerce(op.get("value", null), TYPE_NIL))
			return {"status": "ok", "detail": {"node": str(node11.name), "meta_key": str(op.get("key", ""))}}
		"await_ready":
			return {"status": "deferred"}
	return {"status": "error", "error": "неизвестная операция: %s" % name}


func p_flags(op: Dictionary) -> int:
	var flags := 7
	if op.has("flags"):
		flags = int(op["flags"])
	return flags


func _set_props(target: Object, props: Variant) -> Dictionary:
	if typeof(props) != TYPE_DICTIONARY:
		return {"error": "props должен быть объектом"}
	var applied := []
	for key: Variant in props:
		var prop_path := str(key)
		var raw: Variant = props[key]
		var pieces := prop_path.split("/", false)
		var leaf := pieces[pieces.size() - 1]
		var info: Variant = host.property_info(target, leaf)
		var type_hint := int(info.get("type", 0)) if not info.is_empty() else 0
		if type_hint == TYPE_NIL:
			type_hint = _guess_type(leaf, raw)
		var value: Variant = V.coerce(raw, type_hint)
		var node_path := NodePath("/".join(pieces.slice(0, pieces.size() - 1)) if pieces.size() > 1 else "")
		if pieces.size() > 1:
			var sub := target.get_indexed(node_path)
			if sub == null:
				return {"error": "вложенное свойство не найдено: %s" % prop_path}
			target = sub
			info = host.property_info(target, leaf)
			type_hint = int(info.get("type", 0)) if not info.is_empty() else _guess_type(leaf, raw)
			value = V.coerce(raw, type_hint)
		target.set(leaf, value)
		applied.append({"property": prop_path, "value": V.encode(value), "type": type_string(type_hint)})
	return {"applied": applied}


## Эвристика типа, когда свойство не найдено в property_list (например, у скрипта).
func _guess_type(prop: String, raw: Variant) -> int:
	if prop == "name":
		return TYPE_STRING
	match typeof(raw):
		TYPE_BOOL:
			return TYPE_BOOL
		TYPE_INT:
			return TYPE_INT
		TYPE_FLOAT:
			return TYPE_FLOAT
		TYPE_STRING:
			return TYPE_STRING
		TYPE_ARRAY:
			return TYPE_ARRAY
		TYPE_DICTIONARY:
			if raw.has("$"):
				match str(raw["$"]):
					"Vector2":
						return TYPE_VECTOR2
					"Vector2i":
						return TYPE_VECTOR2I
					"Vector3":
						return TYPE_VECTOR3
					"Color":
						return TYPE_COLOR
					"Resource", "ClassRef":
						return TYPE_OBJECT
					"Rect2":
						return TYPE_RECT2
			return TYPE_DICTIONARY
	return TYPE_NIL


# --- scene.apply_ops (публичная точка входа) -----------------------------------

func _apply_ops_cmd(p: Dictionary) -> Dictionary:
	var path := str(p.get("path", ""))
	if path.is_empty():
		return host.err("Не указан параметр path", "bad_params")
	var res_path: Variant = host.safe_res_path(path)
	var loaded := _load_packed(res_path)
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var root: Node = loaded["root"]
	var applied := _apply_ops(root, p.get("ops", []), false)
	if applied.has("error"):
		root.free()
		return host.err(str(applied["error"]), str(applied.get("code", "op_failed")))
	var out := {
		"path": res_path,
		"ops": applied["applied"],
		"saved": false,
		"dry_run": not bool(p.get("save", false)),
	}
	if bool(p.get("save", false)):
		var backup_enabled := bool(p.get("backup", true))
		if backup_enabled and FileAccess.file_exists(res_path):
			var b := _backup(res_path, int(p.get("keep_backups", 5)))
			if not b.is_empty():
				out["backup"] = b["backup"]
		var packed := PackedScene.new()
		var saved := _save(packed, root, res_path)
		if saved.has("error"):
			root.free()
			return host.err(str(saved["error"]), str(saved["code"]))
		out.merge(saved, true)
	root.free()
	return host.ok(out)


# --- бэкапы -------------------------------------------------------------------

func _backups(p: Dictionary) -> Dictionary:
	var da := DirAccess.open(BACKUP_DIR)
	if da == null:
		return host.ok({"backups": []})
	var file_filter := str(p.get("file", ""))
	var list := []
	da.list_dir_begin()
	var entry := da.get_next()
	while not entry.is_empty():
		# Имена бэкапов: "<метка>_<исходное_имя>.bak", поэтому ищем вхождение, а не суффикс.
		if not da.current_is_dir() and (file_filter.is_empty() or entry.contains("_" + file_filter)):
			list.append({
				"name": entry,
				"path": BACKUP_DIR.path_join(entry),
				"size": FileAccess.get_size(BACKUP_DIR.path_join(entry)),
				"modified": FileAccess.get_modified_time(BACKUP_DIR.path_join(entry)),
			})
		entry = da.get_next()
	da.list_dir_end()
	list.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	list.reverse()
	return host.ok({"backups": list.slice(0, int(p.get("limit", 20))), "dir": ProjectSettings.globalize_path(BACKUP_DIR)})


func _restore(p: Dictionary) -> Dictionary:
	var name := str(p.get("backup", ""))
	if name.is_empty() or name.contains("..") or name.contains("/"):
		return host.err("Укажите имя файла бэкапа (без пути)", "bad_params")
	var src := BACKUP_DIR.path_join(name)
	if not FileAccess.file_exists(src):
		return host.err("Бэкап не найден: %s" % name, "not_found")
	var target: Variant = host.safe_res_path(str(p.get("path", "")))
	if target.is_empty():
		return host.err("Не указан параметр path", "bad_params")
	var current_backup := {}
	if FileAccess.file_exists(target) and bool(p.get("backup_current", true)):
		current_backup = _backup(target, 5)
	var err := DirAccess.copy_absolute(src, target)
	if err != OK:
		return host.err("Не удалось восстановить: %s" % error_string(err), "io_error")
	var out := {"restored": true, "path": target, "from": ProjectSettings.globalize_path(src)}
	if not current_backup.is_empty():
		out["backup"] = current_backup["backup"]
	return host.ok(out)


func handle(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"scene.tree":
			return _tree_cmd(p)
		"scene.state":
			return _state(p)
		"scene.inspect":
			return _inspect(p)
		"scene.create":
			return _create(p)
		"scene.apply_ops":
			return _apply_ops_cmd(p)
		"scene.backups":
			return _backups(p)
		"scene.restore":
			return _restore(p)
	return host.err("Команда не реализована в scene: %s" % cmd, "not_implemented")

@warning_ignore_restore("inference_on_variant")
