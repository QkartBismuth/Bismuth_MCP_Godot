
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Скрипты: структура (символы), метаданные, поиск вызовов по проекту.

const V := preload("res://.mcp/variant.gd")

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args


func commands() -> PackedStringArray:
	return PackedStringArray([
		"script.info",
		"script.symbols",
		"script.read",
		"script.find_references",
	])


func _load(path: String) -> Dictionary:
	var res_path: String = host.safe_res_path(path)
	if not ResourceLoader.exists(res_path):
		return {"error": "Скрипт не найден: %s" % res_path, "code": "not_found"}
	var res: Resource = ResourceLoader.load(res_path)
	if res == null or not (res is Script):
		return {"error": "Файл не является Script: %s" % res_path, "code": "wrong_type"}
	return {"script": res, "path": res_path}


func _info(p: Dictionary) -> Dictionary:
	var loaded: Dictionary = _load(str(p.get("path", "")))
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var s: Script = loaded["script"]
	var code := s.get_source_code()
	return {
		"path": loaded["path"],
		"base_type": s.get_instance_base_type(),
		"global_name": str(s.get_global_name()),
		"is_tool": s.is_tool(),
		"is_abstract": s.is_abstract(),
		"instantiable": s.can_instantiate(),
		"lines": code.split("\n").size(),
		"source_length": code.length(),
		"valid": s.reload() == OK,
		"dependencies": ResourceLoader.get_dependencies(loaded["path"]),
	}


## Структура скрипта: методы, сигналы, свойства, константы, перечисления.
## Базовый класс не разворачивается (его можно посмотреть через classdb.info).
func _symbols(p: Dictionary) -> Dictionary:
	var loaded: Dictionary = _load(str(p.get("path", "")))
	if loaded.has("error"):
		return host.err(str(loaded["error"]), str(loaded["code"]))
	var s: Script = loaded["script"]
	var code := s.get_source_code()
	var lines := code.split("\n")
	var doc := _doc_index(lines)

	var funcs := []
	for m: Dictionary in s.get_script_method_list():
		var arg_list := []
		for a: Variant in m.get("args", []):
			arg_list.append(_arg(a))
		var ret = null
		if m.has("return"):
			ret = _arg(m["return"])
		funcs.append({
			"name": str(m.get("name", "")),
			"args": arg_list,
			"returns": ret,
			"is_static": (int(m.get("flags", 0)) & METHOD_FLAG_STATIC) != 0,
			"is_virtual": _is_virtual(str(m.get("name", ""))),
			"line": _find_line(lines, "func %s" % str(m.get("name", ""))),
			"doc": doc.get(str(m.get("name", "")), ""),
		})
	funcs.sort_custom(func(a, b): return int(a.get("line", 0)) < int(b.get("line", 0)))

	var signals := []
	for sig: Dictionary in s.get_script_signal_list():
		var sig_args := []
		for a: Variant in sig.get("args", []):
			sig_args.append(_arg(a))
		signals.append({
			"name": str(sig.get("name", "")),
			"args": sig_args,
			"line": _find_line(lines, "signal %s" % str(sig.get("name", ""))),
			"doc": doc.get(str(sig.get("name", "")), ""),
		})
	signals.sort_custom(func(a, b): return int(a.get("line", 0)) < int(b.get("line", 0)))

	var vars_out := []
	for v: Dictionary in s.get_script_property_list():
		var usage := int(v.get("usage", 0))
		if usage & PROPERTY_USAGE_CATEGORY or usage & PROPERTY_USAGE_GROUP or usage & PROPERTY_USAGE_SUBGROUP:
			continue
		var var_name := str(v.get("name", ""))
		var line_no := _find_line(lines, "var %s" % var_name)
		var is_onready := line_no > 0 and line_no <= lines.size() and lines[line_no - 1].strip_edges().begins_with("@onready")
		var entry := {
			"name": var_name,
			"type": type_string(int(v.get("type", 0))),
			"class_name": str(v.get("class_name", "")),
			"hint_string": str(v.get("hint_string", "")),
			"exported": (usage & PROPERTY_USAGE_EDITOR) != 0 and (usage & PROPERTY_USAGE_STORAGE) != 0,
			"on_ready": is_onready,
			"line": line_no,
			"doc": doc.get(var_name, ""),
		}
		if not (usage & PROPERTY_USAGE_NO_EDITOR):
			entry["default"] = V.encode(s.get_property_default_value(var_name))
		vars_out.append(entry)
	vars_out.sort_custom(func(a, b): return int(a.get("line", 0)) < int(b.get("line", 0)))

	var const_map := {}
	for k: Variant in s.get_script_constant_map():
		const_map[str(k)] = V.encode(s.get_script_constant_map()[k])

	return {
		"path": loaded["path"],
		"global_name": str(s.get_global_name()),
		"base_type": s.get_instance_base_type(),
		"is_tool": s.is_tool(),
		"functions": funcs,
		"signals": signals,
		"variables": vars_out,
		"constants": const_map,
		"constant_declarations": _constants(lines),
		"enums": _enums(lines),
		"line_count": lines.size(),
	}


func _arg(a: Dictionary) -> Dictionary:
	# Скрипты всегда отдают словари аргументов, но тип подставляем явно.
	return {
		"name": str(a.get("name", "")),
		"type": type_string(int(a.get("type", 0))),
		"class_name": str(a.get("class_name", "")),
		"default": V.encode(a["default_value"]) if a.has("default_value") else null,
	}


func _is_virtual(name: String) -> bool:
	return name.begins_with("_") and name in [
		"_ready", "_process", "_physics_process", "_input", "_unhandled_input", "_init", "_enter_tree",
		"_exit_tree", "_draw", "_notification", "_gui_input", "_shortcut_input", "_unhandled_key_input",
		"_integrate_forces", "_get_configuration_warnings", "_get_property_list", "_set", "_get", "_validate_property",
	]


## Номер строки (с 1) для объявления вида "func name(", "var name", "@export var name".
func _find_line(lines: PackedStringArray, prefix: String) -> int:
	for i: int in range(lines.size()):
		var line: String = lines[i]
		if line.begins_with(prefix):
			return i + 1
		# Аннотация может стоять в той же строке: "@export var speed: float = 1.0"
		var trimmed := line.strip_edges()
		if trimmed.begins_with("@"):
			var without_annotations := _strip_annotations(trimmed)
			if without_annotations.begins_with(prefix):
				return i + 1
	return 0


static func _strip_annotations(line: String) -> String:
	var s := line
	while s.begins_with("@"):
		var space := s.find(" ")
		if space == -1:
			return ""
		var word := s.substr(1, space - 1)
		if word.contains("("):
			var close := s.find(")", space)
			if close == -1:
				return ""
			s = s.substr(close + 1).strip_edges()
		else:
			s = s.substr(space).strip_edges()
	return s


## Собирает docstring-комментарии (## ...) по именам символов.
func _doc_index(lines: PackedStringArray) -> Dictionary:
	var out := {}
	for i: int in range(lines.size()):
		var line: String = lines[i]
		if not line.begins_with("##"):
			continue
		var j := i + 1
		while j < lines.size():
			var next: String = lines[j]
			if next.begins_with("func "):
				out[str(next.trim_prefix("func ").split("(")[0].strip_edges())] = line.trim_prefix("##").strip_edges()
				break
			if next.begins_with("signal "):
				out[str(next.trim_prefix("signal ").split("(")[0].strip_edges())] = line.trim_prefix("##").strip_edges()
				break
			if next.begins_with("var ") or next.begins_with("const "):
				out[str(next.split(" ")[1].split(":")[0].split("=")[0].strip_edges())] = line.trim_prefix("##").strip_edges()
				break
			if next.begins_with("class_name "):
				out["__class__"] = line.trim_prefix("##").strip_edges()
				break
			if not next.begins_with("##"):
				break
			j += 1
	return out


func _constants(lines: PackedStringArray) -> Array:
	var out := []
	for i: int in range(lines.size()):
		var line: String = lines[i]
		if line.begins_with("const ") and not line.begins_with("const_"):
			var body := line.trim_prefix("const ")
			var name := body.split(" ")[0]
			if name == "" or not name.is_valid_identifier():
				continue
			out.append({"name": name, "line": i + 1, "value": body.substr(name.length()).strip_edges().left(120)})
	return out


func _enums(lines: PackedStringArray) -> Array:
	var out := []
	var current := {}
	for i: int in range(lines.size()):
		var line: String = lines[i]
		if line.begins_with("enum "):
			var name := line.trim_prefix("enum ").split(" ")[0].split("{")[0]
			current = {"name": name, "line": i + 1, "values": {}}
			out.append(current)
		elif line.begins_with("}"):
			current = {}
		elif not current.is_empty():
			var parts := line.split("=")
			if parts.size() >= 2:
				current["values"][parts[0].strip_edges().trim_suffix(",")] = parts[1].strip_edges().trim_suffix(",")
	return out


func _read(p: Dictionary) -> Dictionary:
	var res_path: String = host.safe_res_path(str(p.get("path", "")))
	if not FileAccess.file_exists(res_path):
		return host.err("Файл не найден: %s" % res_path, "not_found")
	var f := FileAccess.open(res_path, FileAccess.READ)
	if f == null:
		return host.err("Не удалось открыть файл", "io_error")
	var text := f.get_as_text()
	f.close()
	var from_line := int(p.get("from_line", 1))
	var to_line := int(p.get("to_line", 0))
	var lines := text.split("\n")
	if to_line <= 0:
		to_line = lines.size()
	from_line = maxi(from_line, 1)
	to_line = mini(to_line, lines.size())
	var slice := []
	for i: int in range(from_line - 1, to_line):
		slice.append(fmt("%d: %s", [i + 1, lines[i]]))
	return {
		"path": res_path,
		"from_line": from_line,
		"to_line": to_line,
		"total_lines": lines.size(),
		"text": "\n".join(slice),
	}


## Ищет вызовы вида func_name( в .gd файлах проекта.
func _find_references(p: Dictionary) -> Dictionary:
	var symbol := str(p.get("symbol", ""))
	if symbol.is_empty():
		return host.err("Не указан параметр symbol", "bad_params")
	var limit := int(p.get("limit", 60))
	var include_def := bool(p.get("include_definition", true))
	var dirs: Array = p.get("dirs", ["res://"])
	var hits := []
	var files_scanned := 0
	for dir_path: Variant in dirs:
		var stack := [{"path": str(dir_path), "depth": 0}]
		while not stack.is_empty() and hits.size() < limit:
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
						if int(item["depth"]) < 8 and not entry.begins_with(".") and entry not in [".git", "node_modules"]:
							stack.append({"path": full, "depth": int(item["depth"]) + 1})
					elif entry.ends_with(".gd"):
						files_scanned += 1
						var f := FileAccess.open(full, FileAccess.READ)
						if f == null:
							entry = da.get_next()
							continue
						var lines := f.get_as_text().split("\n")
						f.close()
						for i: int in range(lines.size()):
							var line: String = lines[i]
							if line.contains(symbol) and (include_def or not line.strip_edges().begins_with("func ")):
								hits.append({"path": full, "line": i + 1, "text": line.strip_edges().left(200)})
								if hits.size() >= limit:
									break
				entry = da.get_next()
			da.list_dir_end()
	return {"symbol": symbol, "references": hits, "files_scanned": files_scanned, "truncated": hits.size() >= limit}


func handle(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"script.info":
			return host.ok(_info(p))
		"script.symbols":
			return _symbols(p)
		"script.read":
			return host.ok(_read(p))
		"script.find_references":
			return host.ok(_find_references(p))
	return host.err("Команда не реализована в script: %s" % cmd, "not_implemented")

@warning_ignore_restore("inference_on_variant")
