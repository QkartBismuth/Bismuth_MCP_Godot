
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Ресурсы Godot: инспекция, чтение/запись свойств, поиск ассетов, обратные ссылки.

const V := preload("res://.mcp/variant.gd")
const CORE := preload("res://.mcp/commands/cmd_core.gd")

const TEXT_EXTENSIONS := ["tscn", "tres", "gd", "cfg", "import", "json", "md", "txt", "gdshader", "gdextension", "csv"]
const SKIP_DIRS := [".godot", ".git", "node_modules", ".mcp", ".mcp-backups"]

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args
var _ext_map: Dictionary = {}
var _ext_map_built := false


func commands() -> PackedStringArray:
	return PackedStringArray([
		"resource.info",
		"resource.get",
		"resource.set",
		"resource.create",
		"resource.assets",
		"resource.references",
	])


## Полная карта "расширение -> тип ресурса", собранная из ClassDB.
func _extensions() -> Dictionary:
	if _ext_map_built:
		return _ext_map
	for cls: String in ClassDB.get_class_list():
		if not ClassDB.is_parent_class(cls, "Resource"):
			continue
		for ext: String in ResourceLoader.get_recognized_extensions_for_type(cls):
			if not _ext_map.has(ext):
				_ext_map[ext] = cls
	_ext_map_built = true
	return _ext_map


func _load(path: String) -> Dictionary:
	var res_path: String = host.safe_res_path(path)
	if not ResourceLoader.exists(res_path):
		return {"error": "Ресурс не найден: %s" % res_path, "code": "not_found", "res_path": res_path}
	var res: Resource = ResourceLoader.load(res_path)
	if res == null:
		return {"error": "Не удалось загрузить ресурс: %s" % res_path, "code": "load_error", "res_path": res_path}
	return {"res": res, "res_path": res_path}


func _info(p: Dictionary) -> Dictionary:
	var loaded: Dictionary = _load(str(p.get("path", "")))
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var res: Resource = loaded["res"]
	var res_path: String = loaded["res_path"]
	var uid := ResourceLoader.get_resource_uid(res_path)
	var out := {
		"path": res_path,
		"class": res.get_class(),
		"resource_name": res.resource_name,
		"uid": ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else "",
		"size": host.file_size(res_path) if FileAccess.file_exists(res_path) else -1,
		"modified": FileAccess.get_modified_time(res_path),
	}
	var script := res.get_script()
	if script != null:
		out["script"] = script.resource_path
		if script is Script and (script as Script).get_global_name() != StringName():
			out["script_class"] = str((script as Script).get_global_name())
	var deps := []
	for d: String in ResourceLoader.get_dependencies(res_path):
		deps.append(d)
	if deps.size() > 0:
		out["dependencies"] = deps
	if res is Texture2D:
		var img: Image = (res as Texture2D).get_image()
		if img != null and not img.is_empty():
			out["image"] = {"width": img.get_width(), "height": img.get_height(), "format": str(img.get_format()), "has_mipmaps": img.has_mipmaps()}
	elif res is Image:
		var img2: Image = res
		out["image"] = {"width": img2.get_width(), "height": img2.get_height(), "format": str(img2.get_format())}
	elif res is PackedScene:
		var inst: Node = (res as PackedScene).instantiate()
		out["scene"] = {
			"root": inst.get_class(),
			"root_name": str(inst.name),
			"nodes": _count_nodes(inst),
		}
		inst.free()
	elif res is Script:
		var s: Script = res
		out["script_info"] = {
			"base": s.get_instance_base_type(),
			"global_name": str(s.get_global_name()),
			"instantiable": s.can_instantiate(),
			"lines": s.get_source_code().split("\n").size(),
		}
	elif res is AudioStream:
		out["audio"] = {"length": (res as AudioStream).get_length()}
	elif res is Font:
		out["font"] = {"name": (res as Font).get_font_name()}
	if res.has_method("get_tile_count"):
		out["tile_count"] = res.get_tile_count()
	return out


func _count_nodes(node: Node) -> int:
	var n := 1
	for child: Node in node.get_children():
		n += _count_nodes(child)
	return n


func _read_props(p: Dictionary) -> Dictionary:
	var loaded: Dictionary = _load(str(p.get("path", "")))
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var res: Resource = loaded["res"]
	var names: Array = p.get("props", [])
	var mode := str(p.get("mode", "saved"))
	var collected: Dictionary = host.collect_properties(res, mode, names, int(p.get("limit", 200)))
	var out := {
		"path": loaded["res_path"],
		"class": res.get_class(),
		"properties": collected["properties"],
		"truncated": collected["truncated"],
	}
	if p.has("sub_resources"):
		out["sub_resources"] = _sub_resources(res, int(p.get("sub_limit", 50)))
	return out


## Перечисление встроенных подресурсов (ext_resource) с ключевыми свойствами.
func _sub_resources(res: Resource, limit: int) -> Array:
	var out := []
	if res is PackedScene:
		var state: SceneState = (res as PackedScene).get_state()
		if state == null:
			return out
		for i: int in range(state.get_node_count()):
			var inst: PackedScene = state.get_node_instance(i)
			if inst != null:
				out.append({
					"kind": "instance",
					"path": state.get_node_path(i, false),
					"scene": inst.resource_path,
				})
			if out.size() >= limit:
				return out
	return out


func _write_props(p: Dictionary) -> Dictionary:
	var loaded: Dictionary = _load(str(p.get("path", "")))
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var res: Resource = loaded["res"]
	var items: Array = p.get("items", [])
	var applied := []
	for item: Variant in items:
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = item
		var key := str(entry.get("key", ""))
		if key.is_empty():
			continue
		var info: Dictionary = host.property_info(res, key)
		var type_hint := int(info.get("type", 0)) if not info.is_empty() else 0
		if type_hint == TYPE_NIL and key in res:
			type_hint = typeof(res[key])
		var value: Variant = V.coerce(entry.get("value", null), type_hint)
		res.set(key, value)
		applied.append({"key": key, "value": V.encode(value), "type": type_string(type_hint)})
	var out := {"path": loaded["res_path"], "applied": applied, "saved": false}
	if bool(p.get("save", false)) or p.has("save_as"):
		var target := str(p.get("save_as", loaded["res_path"]))
		var serr := ResourceSaver.save(res, host.safe_res_path(target))
		if serr != OK:
			return host.err(fmt("ResourceSaver.save() вернул %s для %s", [error_string(serr), target]), "save_error")
		out["saved"] = true
		out["path"] = host.safe_res_path(target)
	return out


func _create(p: Dictionary) -> Dictionary:
	var type_name := str(p.get("type", ""))
	var base_path := str(p.get("base", ""))
	var res: Resource = null
	if not base_path.is_empty():
		var loaded: Dictionary = _load(base_path)
		if loaded.has("error"):
			return host.err(str(loaded["error"]), str(loaded["code"]))
		res = (loaded["res"] as Resource).duplicate(true)
	elif not type_name.is_empty():
		if not ClassDB.class_exists(type_name) or not ClassDB.is_parent_class(type_name, "Resource"):
			return host.err("Класс %s не является Resource" % type_name, "bad_params")
		res = ClassDB.instantiate(type_name)
		if res == null:
			return host.err("Не удалось создать экземпляр %s" % type_name, "instantiate_error")
	else:
		return host.err("Укажите type или base", "bad_params")
	var script_path := str(p.get("script", ""))
	if not script_path.is_empty():
		var scr: Resource = ResourceLoader.load(host.safe_res_path(script_path))
		if scr == null:
			return host.err("Не удалось загрузить скрипт %s" % script_path, "not_found")
		res.set_script(scr)
	var applied := []
	for item: Variant in p.get("items", []):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = item
		var key := str(entry.get("key", ""))
		var info: Dictionary = host.property_info(res, key)
		var value: Variant = V.coerce(entry.get("value", null), int(info.get("type", 0)))
		res.set(key, value)
		applied.append(key)
	var target := str(p.get("path", ""))
	if target.is_empty() and not base_path.is_empty():
		target = base_path
	if target.is_empty():
		return {"created": true, "class": res.get_class(), "applied": applied, "saved": false}
	var res_path: String = host.safe_res_path(target)
	var dir: String = res_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var serr := ResourceSaver.save(res, res_path)
	if serr != OK:
		return host.err(fmt("Не удалось сохранить %s: %s", [res_path, error_string(serr)]), "save_error")
	var uid := ResourceLoader.get_resource_uid(res_path)
	return {
		"created": true,
		"path": res_path,
		"class": res.get_class(),
		"applied": applied,
		"saved": true,
		"uid": ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else "",
	}


func _assets(p: Dictionary) -> Dictionary:
	var query := str(p.get("query", "")).to_lower()
	var want_type := str(p.get("type", ""))
	var limit := int(p.get("limit", 100))
	var dir_path := str(p.get("dir", "res://"))
	if not dir_path.begins_with("res://"):
		dir_path = "res://" + dir_path.trim_prefix("/")
	var include_meta := bool(p.get("include_meta", true))
	var ext_map := _extensions()
	var out := []
	var total := 0
	var stack := [{"path": dir_path, "depth": 0}]
	while not stack.is_empty() and out.size() < limit:
		var item: Dictionary = stack.pop_back()
		var da := DirAccess.open(item["path"])
		if da == null:
			continue
		da.list_dir_begin()
		var entry := da.get_next()
		while not entry.is_empty():
			if entry != "." and entry != "..":
				var full: String = str(item["path"]).path_join(entry) if str(item["path"]) != "res://" else "res://" + entry
				if da.current_is_dir():
					if int(item["depth"]) < 10 and not SKIP_DIRS.has(entry) and not entry.begins_with("."):
						stack.append({"path": full, "depth": int(item["depth"]) + 1})
				else:
					var ext := entry.get_extension().to_lower()
					if ext_map.has(ext):
						var rtype: String = ext_map[ext]
						var type_ok: bool = want_type == "" or rtype == want_type or ClassDB.is_parent_class(rtype, want_type)
						if type_ok and query != "":
							type_ok = full.to_lower().contains(query) or entry.to_lower().contains(query)
						if type_ok:
							total += 1
							if out.size() < limit:
								var rec := {"path": full, "name": entry, "type": rtype, "size": host.file_size(full)}
								if include_meta:
									var uid := ResourceLoader.get_resource_uid(full)
									rec["uid"] = ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""
									rec["import_file"] = FileAccess.file_exists(full + ".import")
								out.append(rec)
			entry = da.get_next()
		da.list_dir_end()
	out.sort_custom(func(a, b): return str(a["path"]) < str(b["path"]))
	return {"assets": out, "total_matched": total, "truncated": total > out.size()}


## Ищет упоминания пути (и uid) в текстовых файлах проекта.
func _references(p: Dictionary) -> Dictionary:
	var res_path: String = host.safe_res_path(str(p.get("path", "")))
	var limit := int(p.get("limit", 50))
	var patterns := [res_path]
	var uid := ResourceLoader.get_resource_uid(res_path)
	if uid != ResourceUID.INVALID_ID:
		patterns.append(ResourceUID.id_to_text(uid))
	var found := []
	var files_scanned := 0
	var stack := [{"path": "res://", "depth": 0}]
	while not stack.is_empty() and found.size() < limit:
		var item: Dictionary = stack.pop_back()
		var da := DirAccess.open(item["path"])
		if da == null:
			continue
		da.list_dir_begin()
		var entry := da.get_next()
		while not entry.is_empty():
			if entry != "." and entry != "..":
				var full: String = str(item["path"]).path_join(entry) if str(item["path"]) != "res://" else "res://" + entry
				if da.current_is_dir():
					if int(item["depth"]) < 10 and not SKIP_DIRS.has(entry) and not entry.begins_with("."):
						stack.append({"path": full, "depth": int(item["depth"]) + 1})
				elif entry.get_extension().to_lower() in TEXT_EXTENSIONS:
					files_scanned += 1
					var f := FileAccess.open(full, FileAccess.READ)
					if f == null:
						entry = da.get_next()
						continue
					if f.get_length() > 2097152:
						f.close()
						entry = da.get_next()
						continue
					var text := f.get_as_text()
					f.close()
					var lines := text.split("\n")
					for i: int in range(lines.size()):
						var line: String = lines[i]
						for pattern: String in patterns:
							if line.contains(pattern):
								found.append({
									"path": full,
									"line": i + 1,
									"match": pattern,
									"text": line.strip_edges().left(200),
								})
								break
						if found.size() >= limit:
							break
			entry = da.get_next()
		da.list_dir_end()
	return {"path": res_path, "references": found, "files_scanned": files_scanned, "truncated": found.size() >= limit}


func handle(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"resource.info":
			return _info(p)
		"resource.get":
			return _read_props(p)
		"resource.set":
			return _write_props(p)
		"resource.create":
			return _create(p)
		"resource.assets":
			return _assets(p)
		"resource.references":
			return _references(p)
	return host.err("Команда не реализована в resource: %s" % cmd, "not_implemented")

@warning_ignore_restore("inference_on_variant")
