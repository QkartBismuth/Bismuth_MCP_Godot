
@warning_ignore_start("inference_on_variant")
extends RefCounted
# ClassDB: справка по классам движка (сигнатуры, свойства, сигналы, перечисления).

const V := preload("res://.mcp/variant.gd")

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args
var _class_list: PackedStringArray = PackedStringArray()


func commands() -> PackedStringArray:
	return PackedStringArray([
		"classdb.info",
		"classdb.props",
		"classdb.search",
		"classdb.inheritors",
	])


func _ensure_list() -> PackedStringArray:
	if _class_list.is_empty():
		_class_list = ClassDB.get_class_list()
	return _class_list


func _type_name(t: int) -> String:
	if t == 0:
		return "Variant"
	return type_string(t)


## Часть методов движка отдаёт в args не-Dictionary — приводим любой вариант к словарю.
func _arg_dict(raw: Variant) -> Dictionary:
	var a: Dictionary = raw if typeof(raw) == TYPE_DICTIONARY else {"name": str(raw), "type": 0}
	var d := {"name": str(a.get("name", "")), "type": _type_name(int(a.get("type", 0)))}
	var cls_name := str(a.get("class_name", ""))
	if cls_name != "":
		d["class_name"] = cls_name
	if a.has("default_value"):
		d["default"] = V.encode(a["default_value"])
	return d


func _method_list(cls: String, no_inheritance: bool) -> Array:
	var out := []
	for m: Dictionary in ClassDB.class_get_method_list(cls, no_inheritance):
		var entry := {
			"name": str(m.get("name", "")),
			"args": [],
			"static": (int(m.get("flags", 0)) & METHOD_FLAG_STATIC) != 0,
			"vararg": (int(m.get("flags", 0)) & METHOD_FLAG_VARARG) != 0,
		}
		for a: Variant in m.get("args", []):
			entry["args"].append(_arg_dict(a))
		for a2: Variant in m.get("default_args", []):
			entry["args"].append(_arg_dict(a2))
		if m.has("return"):
			entry["returns"] = _arg_dict(m["return"])
		out.append(entry)
	out.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return out


func _property_list(cls: String, no_inheritance: bool) -> Array:
	var out := []
	for p: Dictionary in ClassDB.class_get_property_list(cls, no_inheritance):
		var usage := int(p.get("usage", 0))
		if usage & PROPERTY_USAGE_CATEGORY or usage & PROPERTY_USAGE_GROUP or usage & PROPERTY_USAGE_SUBGROUP:
			continue
		if usage & PROPERTY_USAGE_INTERNAL:
			continue
		out.append({
			"name": str(p.get("name", "")),
			"type": _type_name(int(p.get("type", 0))),
			"class_name": str(p.get("class_name", "")),
			"hint": str(p.get("hint_string", "")),
			"hint_type": int(p.get("hint", 0)),
			"flags": host.usage_flags(usage),
		})
	out.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return out


func _signal_list(cls: String, no_inheritance: bool) -> Array:
	var out := []
	for s: Dictionary in ClassDB.class_get_signal_list(cls, no_inheritance):
		var args := []
		for a: Variant in s.get("args", []):
			args.append(_arg_dict(a))
		out.append({"name": str(s.get("name", "")), "args": args})
	out.sort_custom(func(a, b): return str(a["name"]) < str(b["name"]))
	return out


func _enum_map(cls: String, no_inheritance: bool) -> Dictionary:
	var out := {}
	for enum_name: String in ClassDB.class_get_enum_list(cls, no_inheritance):
		var constants := {}
		for c: String in ClassDB.class_get_enum_constants(cls, enum_name, no_inheritance):
			constants[c] = ClassDB.class_get_integer_constant(cls, c)
		out[enum_name] = constants
	return out


func _info(p: Dictionary) -> Dictionary:
	var cls := str(p.get("class", ""))
	if cls.is_empty():
		return host.err("Не указан параметр class", "bad_params")
	if not ClassDB.class_exists(cls):
		return host.err("Класс не найден: %s" % cls, "not_found")
	var no_inheritance := bool(p.get("no_inheritance", false))
	var chain := []
	var c := cls
	while c != "":
		chain.append(c)
		c = ClassDB.get_parent_class(c)
	var sections: Array = p.get("sections", ["all"])
	var all := sections.has("all") or sections.is_empty()
	var out := {
		"class": cls,
		"api_type": str(ClassDB.class_get_api_type(cls)),
		"inherits": ClassDB.get_parent_class(cls),
		"chain": chain,
		"instantiable": ClassDB.can_instantiate(cls),
		"enabled": ClassDB.is_class_enabled(cls),
	}
	if all or sections.has("methods"):
		out["methods"] = _method_list(cls, no_inheritance)
	if all or sections.has("properties"):
		out["properties"] = _property_list(cls, no_inheritance)
	if all or sections.has("signals"):
		out["signals"] = _signal_list(cls, no_inheritance)
	if all or sections.has("enums"):
		out["enums"] = _enum_map(cls, no_inheritance)
	if all or sections.has("constants"):
		var consts := {}
		for cname: String in ClassDB.class_get_integer_constant_list(cls, no_inheritance):
			consts[cname] = ClassDB.class_get_integer_constant(cls, cname)
		out["constants"] = consts
	if all or sections.has("project_classes"):
		var globals := []
		for entry: Dictionary in ProjectSettings.get_global_class_list():
			if str(entry.get("base", "")) == cls:
				globals.append(str(entry.get("class", "")))
		out["project_classes"] = globals
	return out


## Разбор PropertyHint.PROPERTY_HINT_ENUM / NODE_TYPE / LAYERS_2D_* -> варианты значения.
func _props(p: Dictionary) -> Dictionary:
	var cls := str(p.get("class", ""))
	var prop := str(p.get("property", ""))
	if not ClassDB.class_exists(cls):
		return host.err("Класс не найден: %s" % cls, "not_found")
	var info := {}
	for entry: Dictionary in ClassDB.class_get_property_list(cls, false):
		if str(entry.get("name", "")) == prop:
			info = entry
	if info.is_empty():
		return host.err(fmt("Свойство %s.%s не найдено", [cls, prop]), "not_found")
	var hint := int(info.get("hint", 0))
	var hint_string := str(info.get("hint_string", ""))
	var out := {
		"class": cls,
		"property": prop,
		"type": _type_name(int(info.get("type", 0))),
		"hint": hint,
		"hint_string": hint_string,
		"usage": host.usage_flags(int(info.get("usage", 0))),
	}
	if hint == PROPERTY_HINT_ENUM or hint == PROPERTY_HINT_ENUM_SUGGESTION:
		var opts := []
		for pair: String in hint_string.split(",", false):
			var parts := pair.split(":", true, 1)
			opts.append({
				"name": parts[0].strip_edges(),
				"value": int(parts[1].strip_edges()) if parts.size() > 1 else 0,
			})
		out["options"] = opts
	elif hint == PROPERTY_HINT_NODE_TYPE:
		var types := []
		for t: String in hint_string.split(",", false):
			t = t.strip_edges()
			if ClassDB.class_exists(t):
				types.append(t)
		out["options"] = types
	elif hint_string != "" and hint_string.is_valid_int():
		out["value"] = hint_string.to_int()
	return out


func _search(p: Dictionary) -> Dictionary:
	var query := str(p.get("query", "")).strip_edges()
	if query.is_empty():
		return host.err("Не указан параметр query", "bad_params")
	var limit := int(p.get("limit", 60))
	var kinds: Array = p.get("kinds", ["class", "method", "property", "signal", "enum", "constant"])
	var case_sensitive := bool(p.get("case_sensitive", false))
	var include_inherited := bool(p.get("include_inherited", false))
	var target_class := str(p.get("class", ""))
	var want_class := target_class != "" and (kinds.has("method") or kinds.has("property") or kinds.has("signal"))
	var results := []
	var needle := query if case_sensitive else query.to_lower()

	if want_class and ClassDB.class_exists(target_class):
		var no_inheritance := not include_inherited
		if kinds.has("method"):
			for m: Dictionary in _method_list(target_class, no_inheritance):
				if _hit(m["name"], needle, case_sensitive):
					results.append({"class": target_class, "kind": "method", "name": m["name"], "signature": _signature(m)})
		if kinds.has("property"):
			for pr: Dictionary in _property_list(target_class, no_inheritance):
				if _hit(pr["name"], needle, case_sensitive):
					results.append({"class": target_class, "kind": "property", "name": pr["name"], "type": pr["type"]})
		if kinds.has("signal"):
			for s: Dictionary in _signal_list(target_class, no_inheritance):
				if _hit(s["name"], needle, case_sensitive):
					results.append({"class": target_class, "kind": "signal", "name": s["name"]})
		var ranked := _rank(results, needle, case_sensitive)
		var top: Array = ranked.slice(0, limit)
		return {"results": top, "total": results.size(), "scope": target_class}

	for cls: String in _ensure_list():
		if results.size() > limit * 8:
			break
		if kinds.has("class") and _hit(cls, needle, case_sensitive):
			results.append({"class": cls, "kind": "class", "name": cls, "inherits": ClassDB.get_parent_class(cls)})
		if not (kinds.has("method") or kinds.has("property") or kinds.has("signal") or kinds.has("enum") or kinds.has("constant")):
			continue
		var no_inheritance := not include_inherited
		if kinds.has("method"):
			for m: Dictionary in ClassDB.class_get_method_list(cls, no_inheritance):
				if _hit(str(m.get("name", "")), needle, case_sensitive):
					results.append({"class": cls, "kind": "method", "name": str(m["name"]), "signature": _signature(_arg_dict_or_empty(m))})
					if results.size() > limit * 8:
						break
		if kinds.has("property"):
			for pr: Dictionary in ClassDB.class_get_property_list(cls, no_inheritance):
				if _hit(str(pr.get("name", "")), needle, case_sensitive):
					results.append({"class": cls, "kind": "property", "name": str(pr["name"]), "type": _type_name(int(pr.get("type", 0)))})
		if kinds.has("signal"):
			for s: Dictionary in ClassDB.class_get_signal_list(cls, no_inheritance):
				if _hit(str(s.get("name", "")), needle, case_sensitive):
					results.append({"class": cls, "kind": "signal", "name": str(s["name"])})
		if kinds.has("enum") or kinds.has("constant"):
			for cname: String in ClassDB.class_get_integer_constant_list(cls, no_inheritance):
				if _hit(cname, needle, case_sensitive):
					results.append({"class": cls, "kind": "enum" if ClassDB.class_has_enum(cls, cname) else "constant", "name": cname, "value": ClassDB.class_get_integer_constant(cls, cname)})
	var ranked := _rank(results, needle, case_sensitive)
	var top: Array = ranked.slice(0, limit)
	return {
		"results": top,
		"total": results.size(),
		"truncated": results.size() > limit,
		"scope": "engine",
	}


func _arg_dict_or_empty(m: Dictionary) -> Dictionary:
	return m


func _signature(m: Dictionary) -> String:
	var parts := []
	for a: Variant in m.get("args", []):
		parts.append(fmt("%s: %s", [a.get("name", "?"), a.get("type", "Variant")]))
	var ret := ""
	if m.has("returns"):
		ret = " -> %s" % m["returns"].get("type", "Variant")
	return fmt("%s(%s)%s", [m.get("name", "?"), ", ".join(parts), ret])


func _hit(value: String, needle: String, case_sensitive: bool) -> bool:
	var hay := value if case_sensitive else value.to_lower()
	return hay.contains(needle)


func _rank(results: Array, needle: String, case_sensitive: bool) -> Array:
	results.sort_custom(func(a, b):
		var sa := _score(a, needle, case_sensitive)
		var sb := _score(b, needle, case_sensitive)
		if sa == sb:
			return str(a["class"]) < str(b["class"])
		return sa < sb)
	return results


func _score(item: Dictionary, needle: String, case_sensitive: bool) -> int:
	var name: String = str(item.get("name", ""))
	var cls: String = str(item.get("class", ""))
	var kind: String = str(item.get("kind", ""))
	var n := name if case_sensitive else name.to_lower()
	var c := cls if case_sensitive else cls.to_lower()
	if kind == "class" and n == needle:
		return 0
	if n == needle:
		return 1
	if kind == "class" and c == needle:
		return 2
	if c == needle:
		return 3
	if n.begins_with(needle):
		return 4
	if c.begins_with(needle):
		return 5
	if n.contains(needle):
		return 6
	return 7


func _inheritors(p: Dictionary) -> Dictionary:
	var cls := str(p.get("class", ""))
	if not ClassDB.class_exists(cls):
		return host.err("Класс не найден: %s" % cls, "not_found")
	var out := []
	for c: String in ClassDB.get_inheriters_from_class(cls):
		out.append(c)
	out.sort()
	var project := []
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if ClassDB.is_parent_class(str(entry.get("base", "")), cls):
			project.append({"class": str(entry.get("class", "")), "base": str(entry.get("base", "")), "path": str(entry.get("path", ""))})
	return {"class": cls, "engine_inheritors": out, "project_classes": project}


func handle(cmd: String, p: Dictionary) -> Dictionary:
	match cmd:
		"classdb.info":
			return _info(p)
		"classdb.props":
			return _props(p)
		"classdb.search":
			return _search(p)
		"classdb.inheritors":
			return host.ok(_inheritors(p))
	return host.err("Команда не реализована в classdb: %s" % cmd, "not_implemented")

@warning_ignore_restore("inference_on_variant")
