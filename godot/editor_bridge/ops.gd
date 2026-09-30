@warning_ignore_start("inference_on_variant")
extends RefCounted
# Применение операций godot_scene_edit к сцене, открытой в редакторе.
# Формат операций совпадает с headless-редактором (см. godot_scene_edit в MCP-сервере).
# host — ссылка на EditorPlugin (для поиска узлов и определения владельца сцены).

const V := preload("res://.mcp/variant.gd")

var host


func apply(root: Node, ops: Variant) -> Dictionary:
	var log := []
	if typeof(ops) != TYPE_ARRAY:
		return {"error": "ops должен быть массивом"}
	for i: int in range(ops.size()):
		var item: Variant = ops[i]
		if typeof(item) != TYPE_DICTIONARY:
			log.append({"index": i, "status": "skipped"})
			continue
		var op: Dictionary = item
		var outcome := _one(root, op)
		outcome["index"] = i
		outcome["op"] = str(op.get("op", ""))
		log.append(outcome)
		if outcome.get("status") == "error":
			return {"error": "Операция #%d (%s): %s" % [i, op.get("op", ""), outcome.get("error", "?")], "log": log}
	return {"log": log, "applied": log.size()}


func _find(path: String) -> Node:
	return host.get_editor_interface().get_edited_scene_root().get_node_or_null(NodePath(path))


func _resolve(root: Node, path: String) -> Node:
	if path.is_empty() or path == ".":
		return root
	return root.get_node_or_null(NodePath(path))


func _one(root: Node, op: Dictionary) -> Dictionary:
	var name := str(op.get("op", ""))
	match name:
		"add_node":
			var parent := _resolve(root, str(op.get("parent", "")))
			if parent == null:
				return {"status": "error", "error": "родитель не найден: %s" % op.get("parent", "")}
			var type_name := str(op.get("type", "Node"))
			if not ClassDB.class_exists(type_name) or not ClassDB.is_parent_class(type_name, "Node"):
				return {"status": "error", "error": "неизвестный тип узла: %s" % type_name}
			var node: Node = ClassDB.instantiate(type_name)
			var node_name := str(op.get("name", type_name))
			if node_name != type_name:
				node.name = node_name
			parent.add_child(node, true)
			node.owner = root
			if op.has("props"):
				var res := _set_props(node, op["props"])
				if res.has("error"):
					return {"status": "error", "error": str(res["error"])}
			if op.has("script"):
				var script_res: Resource = ResourceLoader.load(str(op["script"]))
				if script_res != null and script_res is Script:
					node.set_script(script_res)
			for g: Variant in op.get("groups", []):
				node.add_to_group(str(g))
			return {"status": "ok", "detail": {"node": str(node.name), "type": type_name}}
		"instantiate_scene":
			var parent2 := _resolve(root, str(op.get("parent", "")))
			if parent2 == null:
				return {"status": "error", "error": "родитель не найден"}
			var scene_path := str(op.get("scene", ""))
			if not ResourceLoader.exists(scene_path):
				return {"status": "error", "error": "сцена не найдена: %s" % scene_path}
			var packed: PackedScene = ResourceLoader.load(scene_path)
			if packed == null:
				return {"status": "error", "error": "не удалось загрузить сцену %s" % scene_path}
			var inst: Node = packed.instantiate()
			inst.name = str(op.get("name", inst.name))
			parent2.add_child(inst, true)
			inst.owner = root
			return {"status": "ok", "detail": {"node": str(inst.name), "scene": scene_path}}
		"remove_node":
			var node2 := _resolve(root, str(op.get("path", "")))
			if node2 == null or node2 == root:
				return {"status": "error", "error": "узел не найден или это корень"}
			var parent3 := node2.get_parent()
			parent3.remove_child(node2)
			node2.queue_free()
			return {"status": "ok", "detail": {"removed": str(node2.name)}}
		"duplicate":
			var node3 := _resolve(root, str(op.get("path", "")))
			if node3 == null:
				return {"status": "error", "error": "узел не найден"}
			var copy: Node = node3.duplicate(int(op.get("flags", 7)))
			node3.get_parent().add_child(copy, true)
			copy.owner = root
			if op.has("name"):
				copy.name = str(op["name"])
			return {"status": "ok", "detail": {"node": str(copy.name)}}
		"rename":
			var node4 := _resolve(root, str(op.get("path", "")))
			if node4 == null:
				return {"status": "error", "error": "узел не найден"}
			node4.name = str(op.get("name", ""))
			return {"status": "ok", "detail": {"to": str(node4.name)}}
		"reparent":
			var node5 := _resolve(root, str(op.get("path", "")))
			var target := _resolve(root, str(op.get("new_parent", "")))
			if node5 == null or target == null:
				return {"status": "error", "error": "узел не найден"}
			if node5.is_ancestor_of(target):
				return {"status": "error", "error": "перемещение создаст цикл"}
			node5.get_parent().remove_child(node5)
			target.add_child(node5)
			node5.owner = root
			return {"status": "ok", "detail": {"node": str(node5.name)}}
		"move":
			var node6 := _resolve(root, str(op.get("path", "")))
			if node6 == null or node6.get_parent() == null:
				return {"status": "error", "error": "узел не найден"}
			node6.get_parent().move_child(node6, int(op.get("index", node6.get_index())))
			return {"status": "ok", "detail": {"index": node6.get_index()}}
		"set_props":
			var node7 := _resolve(root, str(op.get("path", "")))
			if node7 == null:
				return {"status": "error", "error": "узел не найден"}
			var res2 := _set_props(node7, op.get("props", {}))
			if res2.has("error"):
				return {"status": "error", "error": str(res2["error"])}
			return {"status": "ok", "detail": {"node": str(node7.name), "applied": res2["applied"]}}
		"group":
			var node8 := _resolve(root, str(op.get("path", "")))
			if node8 == null:
				return {"status": "error", "error": "узел не найден"}
			for g2: Variant in op.get("add", []):
				node8.add_to_group(str(g2))
			for g3: Variant in op.get("remove", []):
				node8.remove_from_group(str(g3))
			return {"status": "ok", "detail": {"groups": node8.get_groups()}}
		"script":
			var node9 := _resolve(root, str(op.get("path", "")))
			if node9 == null:
				return {"status": "error", "error": "узел не найден"}
			if bool(op.get("detach", false)):
				node9.set_script(null)
				return {"status": "ok", "detail": {"script": null}}
			var scr2: Resource = ResourceLoader.load(str(op.get("attach", "")))
			if scr2 == null or not (scr2 is Script):
				return {"status": "error", "error": "скрипт не найден"}
			node9.set_script(scr2)
			return {"status": "ok", "detail": {"script": str(op["attach"])}}
		"connect":
			var from_node := _resolve(root, str(op.get("from", op.get("path", ""))))
			var to_node := _resolve(root, str(op.get("to", "")))
			if from_node == null or to_node == null:
				return {"status": "error", "error": "узел не найден"}
			var sig := str(op.get("signal", ""))
			var method := str(op.get("method", ""))
			if not from_node.has_signal(sig):
				return {"status": "error", "error": "нет сигнала %s" % sig}
			if not to_node.has_method(method):
				return {"status": "error", "error": "нет метода %s" % method}
			var cb := Callable(to_node, method)
			if from_node.is_connected(sig, cb):
				from_node.disconnect(sig, cb)
			from_node.connect(sig, cb, int(op.get("flags", CONNECT_PERSIST)))
			return {"status": "ok", "detail": {"signal": sig, "method": method}}
	return {"status": "error", "error": "неизвестная операция: %s" % name}


func _set_props(target: Object, props: Variant) -> Dictionary:
	if typeof(props) != TYPE_DICTIONARY:
		return {"error": "props должен быть объектом"}
	var applied := []
	for key: Variant in props:
		var leaf := str(key)
		var info := _prop_info(target, leaf)
		var value: Variant = V.coerce(props[key], int(info.get("type", 0)))
		target.set(leaf, value)
		applied.append({"property": leaf, "value": V.encode(value)})
	return {"applied": applied}


func _prop_info(target: Object, prop: String) -> Dictionary:
	for p: Dictionary in target.get_property_list():
		if str(p["name"]) == prop:
			return p
	return {}

@warning_ignore_restore("inference_on_variant")
