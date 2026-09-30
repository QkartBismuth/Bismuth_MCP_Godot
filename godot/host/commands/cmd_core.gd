
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Базовые команды: информация о проекте, настройки, файлы, uid.

const V := preload("res://.mcp/variant.gd")

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args


func commands() -> PackedStringArray:
	return PackedStringArray([
		"host.info",
		"project.info",
		"project.settings",
		"project.autoloads",
		"project.input_actions",
		"project.export_presets",
		"project.global_classes",
		"file.list",
		"file.read",
		"file.write",
		"file.stat",
		"uid.lookup",
	])


# --- host.info ----------------------------------------------------------------

func _host_info() -> Dictionary:
	return {
		"protocol": 1,
		"pid": OS.get_process_id(),
		"engine": Engine.get_version_info(),
		"os": {
			"name": OS.get_name(),
			"distro": OS.get_distribution_name(),
			"arch": OS.get_processor_name(),
			"cmdline": OS.get_cmdline_args(),
			"user_args": OS.get_cmdline_user_args(),
		},
		"display": {
			"server": DisplayServer.get_name(),
			"screen_count": DisplayServer.get_screen_count(),
			"window_size": DisplayServer.window_get_size(),
			"rendering_method": ProjectSettings.get_setting("rendering/renderer/rendering_method", ""),
			"rendering_driver": RenderingServer.get_video_adapter_name(),
		},
		"project": {
			"root": ProjectSettings.globalize_path("res://"),
			"name": ProjectSettings.get_setting("application/config/name", ""),
			"main_scene": ProjectSettings.get_setting("application/run/main_scene", ""),
			"config_version": ProjectSettings.get_setting("config_version", 0),
		},
		"import": {
			"imported": DirAccess.dir_exists_absolute("res://.godot/imported"),
			"uid_cache": FileAccess.file_exists("res://.godot/uid_cache.bin"),
			"editor_files": FileAccess.file_exists("res://.godot/editor/filesystem_cache8"),
		},
		"runtime": host.runtime_status(),
		"gdscript": {
			"global_classes": ProjectSettings.get_global_class_list().size(),
		},
	}


# --- project.info -------------------------------------------------------------

func _layer_names(key: String) -> Dictionary:
	var out := {}
	var value: Variant = ProjectSettings.get_setting(key, null)
	if typeof(value) == TYPE_DICTIONARY:
		for k: Variant in value:
			out[str(k)] = str(value[k])
	return out


func _project_info() -> Dictionary:
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.begins_with("uid://"):
		var resolved := ResourceUID.get_id_path(ResourceUID.text_to_id(main_scene))
		if resolved != "":
			main_scene = resolved
	var features := []
	var raw_features: Variant = ProjectSettings.get_setting("application/config/features", PackedStringArray())
	if typeof(raw_features) == TYPE_PACKED_STRING_ARRAY or typeof(raw_features) == TYPE_ARRAY:
		for f: Variant in raw_features:
			features.append(str(f))
	return {
		"name": ProjectSettings.get_setting("application/config/name", ""),
		"version": ProjectSettings.get_setting("application/config/version", ""),
		"description": ProjectSettings.get_setting("application/config/description", ""),
		"features": features,
		"main_scene": main_scene,
		"boot_splash": ProjectSettings.get_setting("application/boot_splash/bg_color", ""),
		"viewport": {
			"width": ProjectSettings.get_setting("display/window/size/viewport_width", 0),
			"height": ProjectSettings.get_setting("display/window/size/viewport_height", 0),
			"stretch_mode": ProjectSettings.get_setting("display/window/stretch/mode", ""),
			"orientation": ProjectSettings.get_setting("display/window/handheld/orientation", ""),
		},
		"renderer": ProjectSettings.get_setting("rendering/renderer/rendering_method", ""),
		"physics_2d": ProjectSettings.get_setting("physics/2d/default_gravity", 0),
		"physics_3d": ProjectSettings.get_setting("physics/3d/default_gravity", 0),
		"layers": {
			"2d_render": _layer_names("layer_names/2d_render"),
			"2d_physics": _layer_names("layer_names/2d_physics"),
			"2d_navigation": _layer_names("layer_names/2d_navigation"),
			"3d_render": _layer_names("layer_names/3d_render"),
			"3d_physics": _layer_names("layer_names/3d_physics"),
			"3d_navigation": _layer_names("layer_names/3d_navigation"),
		},
		"autoloads": _autoloads(),
		"editor_plugins": _string_array_setting("editor_plugins/enabled"),
		"global_classes": ProjectSettings.get_global_class_list().size(),
		"has_export_presets": FileAccess.file_exists("res://export_presets.cfg"),
		"has_input_map": not InputMap.get_actions().is_empty(),
	}


func _string_array_setting(key: String) -> Array:
	var out := []
	var value: Variant = ProjectSettings.get_setting(key, null)
	if typeof(value) == TYPE_ARRAY or typeof(value) == TYPE_PACKED_STRING_ARRAY:
		for item: Variant in value:
			out.append(str(item))
	return out


## Автолоаны читаются напрямую из настроек: "*" в значении означает singleton.
func _autoloads() -> Array:
	var out := []
	for setting: String in _settings_with_prefix("autoload/"):
		var value: Variant = ProjectSettings.get_setting(setting, "")
		var text := str(value)
		var singleton := text.begins_with("*")
		if singleton:
			text = text.substr(1)
		out.append({"name": setting.trim_prefix("autoload/"), "path": text, "singleton": singleton})
	out.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return out


func _settings_with_prefix(prefix: String) -> PackedStringArray:
	var out := PackedStringArray()
	for prop: Dictionary in ProjectSettings.get_property_list():
		var name := str(prop["name"])
		if name.begins_with(prefix):
			out.append(name)
	out.sort()
	return out


func _input_actions() -> Dictionary:
	var actions := InputMap.get_actions()
	var out := {}
	for action: StringName in actions:
		var events := []
		for ev: InputEvent in InputMap.action_get_events(action):
			events.append(_describe_input_event(ev))
		out[str(action)] = {
			"deadzone": InputMap.action_get_deadzone(action),
			"events": events,
			"builtin": not ProjectSettings.has_setting("input/" + str(action)),
		}
	return out


func _describe_input_event(ev: InputEvent) -> Dictionary:
	var d := {"type": ev.get_class()}
	if ev is InputEventKey:
		var k: InputEventKey = ev
		d["keycode"] = OS.get_keycode_string(k.keycode)
		d["physical"] = OS.get_keycode_string(k.physical_keycode)
		d["pressed"] = k.pressed
		d["echo"] = k.echo
		if k.ctrl_pressed:
			d["ctrl"] = true
		if k.alt_pressed:
			d["alt"] = true
		if k.shift_pressed:
			d["shift"] = true
		if k.meta_pressed:
			d["meta"] = true
	elif ev is InputEventMouseButton:
		var m: InputEventMouseButton = ev
		d["button_index"] = m.button_index
		d["pressed"] = m.pressed
		d["position"] = V.encode(m.position)
	elif ev is InputEventMouseMotion:
		var mm: InputEventMouseMotion = ev
		d["position"] = V.encode(mm.position)
		d["relative"] = V.encode(mm.relative)
	elif ev is InputEventJoypadButton:
		var jb: InputEventJoypadButton = ev
		d["button_index"] = jb.button_index
		d["pressed"] = jb.pressed
	elif ev is InputEventJoypadMotion:
		var jm: InputEventJoypadMotion = ev
		d["axis"] = jm.axis
		d["axis_value"] = jm.axis_value
	elif ev is InputEventAction:
		d["action"] = str((ev as InputEventAction).action)
	return d


func _global_classes() -> Array:
	var out := []
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		out.append({
			"class": str(entry.get("class", "")),
			"language": str(entry.get("language", "")),
			"path": str(entry.get("path", "")),
			"base": str(entry.get("base", "")),
			"icon": str(entry.get("icon", "")),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["class"]) < str(b["class"]))
	return out


func _export_presets() -> Dictionary:
	var path := "res://export_presets.cfg"
	if not FileAccess.file_exists(path):
		return {"presets": [], "present": false}
	var cfg := ConfigFile.new()
	var err := cfg.load(path)
	if err != OK:
		return host.err("Не удалось разобрать export_presets.cfg: %s" % error_string(err), "parse_error")
	var presets := []
	for section: String in cfg.get_sections():
		if not section.begins_with("preset."):
			continue
		var idx := section.trim_prefix("preset.")
		presets.append({
			"id": idx,
			"name": str(cfg.get_value(section, "name", "")),
			"platform": str(cfg.get_value(section, "platform", "")),
			"runnable": bool(cfg.get_value(section, "runnable", false)),
			"export_path": str(cfg.get_value(section, "export_path", "")),
			"export_filter": str(cfg.get_value(section, "export_filter", "")),
			"custom_features": str(cfg.get_value(section, "custom_features", "")),
		})
	return {"presets": presets, "present": true}


# --- project.settings ---------------------------------------------------------

func _settings(p: Dictionary) -> Dictionary:
	var mode := str(p.get("mode", "list"))
	match mode:
		"get":
			var keys: Array = p.get("keys", [])
			var out := {}
			for key: Variant in keys:
				var k := str(key)
				out[k] = V.encode(ProjectSettings.get_setting(k, null))
			return {"settings": out}
		"set":
			var items: Array = p.get("items", [])
			var applied := []
			for item: Variant in items:
				if typeof(item) != TYPE_DICTIONARY:
					continue
				var entry: Dictionary = item
				var key := str(entry.get("key", ""))
				if key.is_empty():
					continue
				var info := _setting_info(key)
				var value: Variant = V.coerce(entry.get("value", null), int(info.get("type", 0)))
				ProjectSettings.set_setting(key, value)
				applied.append({"key": key, "value": V.encode(value)})
			var saved := false
			if bool(p.get("save", false)):
				var serr := ProjectSettings.save()
				if serr != OK:
					return host.err("ProjectSettings.save() вернул %s" % error_string(serr), "save_error")
				saved = true
			return {"applied": applied, "saved": saved}
		_:
			var prefix := str(p.get("prefix", ""))
			var names := PackedStringArray()
			for prop: Dictionary in ProjectSettings.get_property_list():
				var name := str(prop["name"])
				if prefix.is_empty() or name.begins_with(prefix):
					names.append(name)
			names.sort()
			var limit := int(p.get("limit", 400))
			var out_map := {}
			var i := 0
			for name: String in names:
				if i >= limit:
					return {"settings": out_map, "truncated": true, "total": names.size()}
				out_map[name] = V.encode(ProjectSettings.get_setting(name, null))
				i += 1
			return {"settings": out_map, "total": names.size(), "truncated": false}


func _setting_info(key: String) -> Dictionary:
	for prop: Dictionary in ProjectSettings.get_property_list():
		if str(prop["name"]) == key:
			return prop
	return {}


# --- файлы --------------------------------------------------------------------

const SKIP_DIRS := [".godot", ".git", ".import", "node_modules", ".mcp", ".mcp-backups"]

const REGEX_SPECIALS := "\\.[](){}|?*+^$"

static func glob_to_regex(pattern: String) -> RegEx:
	var regex := "^"
	var i := 0
	while i < pattern.length():
		var c := pattern[i]
		if c == "*":
			if i + 1 < pattern.length() and pattern[i + 1] == "*":
				regex += "(?:.*/)?"
				i += 2
				if i < pattern.length() and pattern[i] == "/":
					i += 1
				continue
			regex += "[^/]*"
		elif c == "?":
			regex += "[^/]"
		else:
			if REGEX_SPECIALS.contains(c):
				regex += "\\"
			regex += c
		i += 1
	regex += "$"
	var re := RegEx.new()
	re.compile(regex)
	return re


## include=[] означает "все файлы", exclude=[] — "ничего не исключать".
## Паттерн проверяется и по относительному пути, и по имени файла:
## так "*.gd" находит скрипты на любой вложенности, а "src/**" — только каталог src.
func _matches(rel: String, patterns: Array) -> bool:
	if patterns.is_empty():
		return true
	var file_name := rel.get_file()
	for p: Variant in patterns:
		var pattern := str(p)
		if glob_to_regex(pattern).search(rel) != null:
			return true
		if glob_to_regex(pattern).search(file_name) != null:
			return true
	return false


func _excluded(rel: String, patterns: Array) -> bool:
	if patterns.is_empty():
		return false
	return _matches(rel, patterns)


func _file_list(p: Dictionary) -> Dictionary:
	var base_dir := str(p.get("dir", "res://"))
	if not base_dir.begins_with("res://"):
		base_dir = "res://" + base_dir.trim_prefix("/")
	var base_path := ProjectSettings.globalize_path(base_dir)
	var patterns: Array = p.get("include", [])
	var exclude: Array = p.get("exclude", [])
	var limit := int(p.get("limit", 500))
	var max_depth := int(p.get("max_depth", 12))
	var show_dirs := bool(p.get("directories", false))
	var files := []
	var dirs := []
	var total := 0
	var truncated := false

	var stack := [{"path": base_dir, "depth": 0}]
	while not stack.is_empty():
		var item: Dictionary = stack.pop_back()
		var dir_path: String = item["path"]
		var depth: int = item["depth"]
		var da := DirAccess.open(dir_path)
		if da == null:
			continue
		da.list_dir_begin()
		var entry := da.get_next()
		while not entry.is_empty():
			if entry != "." and entry != "..":
				var full := dir_path.path_join(entry) if dir_path != "res://" else "res://" + entry
				var rel := full.trim_prefix(base_dir).trim_prefix("/")
				if da.current_is_dir():
					if depth < max_depth and not SKIP_DIRS.has(entry) and not entry.begins_with("."):
						dirs.append({"path": full, "name": entry})
						stack.append({"path": full, "depth": depth + 1})
				elif _matches(rel, patterns) and not _excluded(rel, exclude):
					total += 1
					if files.size() < limit:
						files.append({
							"path": full,
							"name": entry,
							"size": FileAccess.get_size(full) if FileAccess.file_exists(full) else -1,
						})
					else:
						truncated = true
			entry = da.get_next()
		da.list_dir_end()
	files.sort_custom(func(a, b): return str(a["path"]) < str(b["path"]))
	return {
		"dir": base_dir,
		"real_dir": base_path,
		"files": files,
		"directories": dirs if show_dirs else [],
		"total_matched": total,
		"truncated": truncated,
	}


func _file_read(p: Dictionary) -> Dictionary:
	var path := str(p.get("path", ""))
	if path.is_empty():
		return host.err("Не указан параметр path", "bad_params")
	var res_path: String = host.safe_res_path(path)
	if not FileAccess.file_exists(res_path):
		return host.err("Файл не найден: %s" % res_path, "not_found")
	var max_bytes := int(p.get("max_bytes", 262144))
	var size := FileAccess.get_size(res_path)
	var offset := int(p.get("offset", 0))
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return host.err(fmt("Не удалось открыть %s: %s", [res_path, error_string(FileAccess.get_open_error())]), "io_error")
	if offset > 0:
		f.seek(offset)
	var to_read := mini(size - offset, max_bytes)
	var bytes := f.get_buffer(maxi(to_read, 0))
	f.close()
	var binary := bool(p.get("binary", false))
	var out := {
		"path": res_path,
		"size": size,
		"offset": offset,
		"read": bytes.size(),
		"truncated": bytes.size() < size - offset,
		"modified": FileAccess.get_modified_time(res_path),
	}
	if binary:
		out["base64"] = Marshalls.raw_to_base64(bytes)
	else:
		out["text"] = bytes.get_string_from_utf8()
	return out


func _file_write(p: Dictionary) -> Dictionary:
	var path := str(p.get("path", ""))
	if path.is_empty():
		return host.err("Не указан параметр path", "bad_params")
	var res_path: String = host.safe_res_path(path)
	var content := str(p.get("content", ""))
	var append := bool(p.get("append", false))
	var existed := FileAccess.file_exists(res_path)
	if not existed and bool(p.get("create_dirs", true)):
		var dir: String = res_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(dir):
			var derr := DirAccess.make_dir_recursive_absolute(dir)
			if derr != OK:
				return host.err(fmt("Не удалось создать каталог %s: %s", [dir, error_string(derr)]), "io_error")
	var mode := FileAccess.READ_WRITE if append and existed else FileAccess.WRITE
	var f := FileAccess.open(res_path, mode)
	if f == null:
		return host.err(fmt("Не удалось открыть %s для записи: %s", [res_path, error_string(FileAccess.get_open_error())]), "io_error")
	if append and existed:
		f.seek_end()
	f.store_string(content)
	f.close()
	return {"path": res_path, "bytes": content.length(), "created": not existed}


var _ext_types: Dictionary = {}


## Тип ресурса по расширению (ResourceLoader.get_resource_type() недоступен из скриптов).
func _type_by_extension(ext: String) -> String:
	if _ext_types.is_empty():
		for cls: String in ClassDB.get_class_list():
			if not ClassDB.is_parent_class(cls, "Resource"):
				continue
			for e: String in ResourceLoader.get_recognized_extensions_for_type(cls):
				if not _ext_types.has(e):
					_ext_types[e] = cls
	return str(_ext_types.get(ext, ""))


func _file_stat(p: Dictionary) -> Dictionary:
	var res_path: String = host.safe_res_path(str(p.get("path", "")))
	var is_file := FileAccess.file_exists(res_path)
	var is_dir := DirAccess.dir_exists_absolute(res_path)
	if not is_file and not is_dir:
		return host.err("Путь не существует: %s" % res_path, "not_found")
	var type_name := ""
	if is_file:
		type_name = _type_by_extension(res_path.get_extension().to_lower())
		if type_name == "":
			type_name = "file"
	var out := {
		"path": res_path,
		"exists": true,
		"is_file": is_file,
		"is_dir": is_dir,
	}
	if is_file:
		out["size"] = FileAccess.get_size(res_path)
		out["modified"] = FileAccess.get_modified_time(res_path)
		out["resource_type"] = type_name
		var uid := ResourceLoader.get_resource_uid(res_path)
		if uid != ResourceUID.INVALID_ID:
			out["uid"] = ResourceUID.id_to_text(uid)
	else:
		var count := 0
		var da := DirAccess.open(res_path)
		if da != null:
			count = _count_files(da, 0)
		out["file_count"] = count
	return out


func _count_files(da: DirAccess, depth: int) -> int:
	if depth > 6:
		return 0
	var n := 0
	da.list_dir_begin()
	var entry := da.get_next()
	while not entry.is_empty():
		if entry != "." and entry != "..":
			if da.current_is_dir():
				if not SKIP_DIRS.has(entry) and not entry.begins_with("."):
					var sub := DirAccess.open(da.get_current_dir().path_join(entry))
					if sub != null:
						n += _count_files(sub, depth + 1)
			else:
				n += 1
		entry = da.get_next()
	da.list_dir_end()
	return n


func _uid_lookup(p: Dictionary) -> Dictionary:
	var out := {}
	if p.has("uid"):
		var text := str(p["uid"])
		var id := ResourceUID.text_to_id(text)
		out["uid"] = text
		out["valid"] = ResourceUID.has_id(id)
		out["path"] = ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	if p.has("path"):
		var res_path: String = host.safe_res_path(str(p["path"]))
		var uid := ResourceLoader.get_resource_uid(res_path)
		out["path"] = res_path
		out["uid"] = ResourceUID.id_to_text(uid) if uid != ResourceUID.INVALID_ID else ""
		out["valid"] = uid != ResourceUID.INVALID_ID
	return out


# --- диспетчер ----------------------------------------------------------------

func handle(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"host.info":
			return host.ok(_host_info())
		"project.info":
			return host.ok(_project_info())
		"project.settings":
			return _settings(p)
		"project.autoloads":
			return host.ok({"autoloads": _autoloads()})
		"project.input_actions":
			return host.ok({"actions": _input_actions()})
		"project.export_presets":
			return _export_presets()
		"project.global_classes":
			return host.ok({"classes": _global_classes()})
		"file.list":
			return _file_list(p)
		"file.read":
			return _file_read(p)
		"file.write":
			return _file_write(p)
		"file.stat":
			return _file_stat(p)
		"uid.lookup":
			return host.ok(_uid_lookup(p))
	return host.err("Команда не реализована в core: %s" % cmd, "not_implemented")

@warning_ignore_restore("inference_on_variant")
