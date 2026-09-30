
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Конвертация Variant <-> JSON-совместимые значения для протокола MCP.
# Файл копируется сервером в <project>/.mcp/, class_name намеренно не используется,
# чтобы не регистрировать глобальный класс в проекте пользователя.

const MAX_DEPTH := 14
const MAX_ARRAY := 1024
const MAX_B64 := 8192
const MAX_STRING := 16384


static func encode(v: Variant, depth: int = 0) -> Variant:
	if depth > MAX_DEPTH:
		return {"$": "truncated", "reason": "max_depth"}
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT:
			return v
		TYPE_FLOAT:
			if is_nan(v):
				return "nan"
			if is_inf(v):
				return "inf" if v > 0.0 else "-inf"
			return v
		TYPE_STRING, TYPE_STRING_NAME:
			return _clip(str(v))
		TYPE_NODE_PATH:
			return str(v)
		TYPE_VECTOR2:
			return {"$": "Vector2", "x": v.x, "y": v.y}
		TYPE_VECTOR2I:
			return {"$": "Vector2i", "x": v.x, "y": v.y}
		TYPE_VECTOR3:
			return {"$": "Vector3", "x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR3I:
			return {"$": "Vector3i", "x": v.x, "y": v.y, "z": v.z}
		TYPE_VECTOR4:
			return {"$": "Vector4", "x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_VECTOR4I:
			return {"$": "Vector4i", "x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_RECT2:
			return {"$": "Rect2", "x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_RECT2I:
			return {"$": "Rect2i", "x": v.position.x, "y": v.position.y, "w": v.size.x, "h": v.size.y}
		TYPE_COLOR:
			return {"$": "Color", "hex": v.to_html(true), "r": v.r, "g": v.g, "b": v.b, "a": v.a}
		TYPE_PLANE:
			return {"$": "Plane", "x": v.normal.x, "y": v.normal.y, "z": v.normal.z, "d": v.d}
		TYPE_QUATERNION:
			return {"$": "Quaternion", "x": v.x, "y": v.y, "z": v.z, "w": v.w}
		TYPE_AABB:
			return {"$": "AABB", "position": encode(v.position, depth + 1), "size": encode(v.size, depth + 1)}
		TYPE_BASIS:
			return {"$": "Basis", "x": encode(v.x, depth + 1), "y": encode(v.y, depth + 1), "z": encode(v.z, depth + 1)}
		TYPE_TRANSFORM2D:
			return {
				"$": "Transform2D",
				"x": encode(v.x, depth + 1),
				"y": encode(v.y, depth + 1),
				"origin": encode(v.origin, depth + 1),
			}
		TYPE_TRANSFORM3D:
			return {
				"$": "Transform3D",
				"basis": encode(v.basis, depth + 1),
				"origin": encode(v.origin, depth + 1),
			}
		TYPE_PROJECTION:
			return {
				"$": "Projection",
				"x": encode(v.x, depth + 1),
				"y": encode(v.y, depth + 1),
				"z": encode(v.z, depth + 1),
				"w": encode(v.w, depth + 1),
			}
		TYPE_RID:
			return {"$": "RID", "id": v.get_id()}
		TYPE_CALLABLE:
			var obj: Object = v.get_object()
			return {
				"$": "Callable",
				"valid": v.is_valid(),
				"method": str(v.get_method()),
				"object": _short_object(obj),
			}
		TYPE_SIGNAL:
			return {"$": "Signal", "name": str(v.get_name()), "object": _short_object(v.get_object())}
		TYPE_DICTIONARY:
			var out := {}
			if v.size() > MAX_ARRAY:
				return {"$": "truncated", "reason": "dict_too_large", "size": v.size()}
			for k: Variant in v:
				out[_key(k)] = encode(v[k], depth + 1)
			return out
		TYPE_ARRAY:
			var arr := []
			var n: int = mini(v.size(), MAX_ARRAY)
			for i: int in range(n):
				arr.append(encode(v[i], depth + 1))
			if v.size() > n:
				arr.append({"$": "truncated", "reason": "array_too_large", "size": v.size()})
			return arr
		TYPE_PACKED_BYTE_ARRAY:
			if v.size() > MAX_B64:
				return {"$": "PackedByteArray", "size": v.size()}
			return {"$": "PackedByteArray", "size": v.size(), "base64": Marshalls.raw_to_base64(v)}
		TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, \
		TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, \
		TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			var out_a := []
			var n2: int = mini(v.size(), MAX_ARRAY)
			for i2: int in range(n2):
				out_a.append(encode(v[i2], depth + 1))
			var d := {"$": type_string(typeof(v)), "size": v.size(), "values": out_a}
			if v.size() > n2:
				d["truncated"] = true
			return d
		TYPE_OBJECT:
			return _object(v, depth)
	return _clip(str(v))


static func _object(o: Object, depth: int) -> Variant:
	if o == null:
		return null
	if not is_instance_valid(o):
		return {"$": "Object", "class": o.get_class(), "valid": false}
	if o is Resource:
		var res: Resource = o
		var d := {"$": "Resource", "class": res.get_class(), "path": res.resource_path}
		if res.resource_name != "":
			d["name"] = res.resource_name
		if res is Script:
			var s: Script = res
			d["script"] = true
			if s.get_global_name() != StringName():
				d["class_name"] = str(s.get_global_name())
		return d
	if o is Node:
		var n: Node = o
		var nd := {"$": "Node", "class": n.get_class(), "name": n.name}
		if n.is_inside_tree():
			nd["path"] = str(n.get_path())
			nd["scene"] = n.scene_file_path
		else:
			nd["path"] = null
		return nd
	if o is Object:
		return _short_object(o)
	return {"$": "Object", "class": o.get_class()}


static func _short_object(o: Object) -> Variant:
	if o == null or not is_instance_valid(o):
		return null
	if o is Node and (o as Node).is_inside_tree():
		return {"class": o.get_class(), "path": str((o as Node).get_path())}
	if o is Resource:
		return {"class": o.get_class(), "path": (o as Resource).resource_path}
	return {"class": o.get_class()}


static func _key(k: Variant) -> String:
	match typeof(k):
		TYPE_STRING, TYPE_STRING_NAME:
			return str(k)
		TYPE_INT:
			return str(k)
		TYPE_FLOAT:
			return str(k)
	return str(k)


static func _clip(s: String) -> String:
	if s.length() <= MAX_STRING:
		return s
	return s.substr(0, MAX_STRING) + "…[+%d chars]" % (s.length() - MAX_STRING)


# --- Обратное преобразование: JSON -> Variant нужного типа ---------------------

## Приводит значение к Variant::Type, используя подсказку типа свойства.
static func coerce(value: Variant, type_hint: int = TYPE_NIL) -> Variant:
	if type_hint == TYPE_NIL:
		return _auto(value)
	match type_hint:
		TYPE_NIL:
			return null
		TYPE_BOOL:
			return _to_bool(value)
		TYPE_INT:
			return int(_to_num(value))
		TYPE_FLOAT:
			return float(_to_num(value))
		TYPE_STRING, TYPE_STRING_NAME:
			return str(value) if typeof(value) != TYPE_STRING else value
		TYPE_VECTOR2:
			return _vec(value, 2, TYPE_FLOAT)
		TYPE_VECTOR2I:
			return _vec(value, 2, TYPE_INT)
		TYPE_VECTOR3:
			return _vec(value, 3, TYPE_FLOAT)
		TYPE_VECTOR3I:
			return _vec(value, 3, TYPE_INT)
		TYPE_VECTOR4:
			return _vec(value, 4, TYPE_FLOAT)
		TYPE_VECTOR4I:
			return _vec(value, 4, TYPE_INT)
		TYPE_COLOR:
			return _color(value)
		TYPE_RECT2:
			var rv := _vec(value, 4, TYPE_FLOAT)
			return Rect2(rv[0], rv[1], rv[2], rv[3])
		TYPE_RECT2I:
			var ri := _vec(value, 4, TYPE_INT)
			return Rect2i(ri[0], ri[1], ri[2], ri[3])
		TYPE_QUATERNION:
			var q := _vec(value, 4, TYPE_FLOAT)
			return Quaternion(q[0], q[1], q[2], q[3])
		TYPE_PLANE:
			var pl := _vec(value, 4, TYPE_FLOAT)
			return Plane(pl[0], pl[1], pl[2], pl[3])
		TYPE_AABB:
			if typeof(value) == TYPE_DICTIONARY and value.has("position"):
				return AABB(_vec(value["position"], 3, TYPE_FLOAT), _vec(value.get("size", Vector3.ZERO), 3, TYPE_FLOAT))
			return _from_str(value, TYPE_AABB)
		TYPE_BASIS:
			if typeof(value) == TYPE_DICTIONARY and value.has("x"):
				return Basis(_vec(value["x"], 3, TYPE_FLOAT), _vec(value["y"], 3, TYPE_FLOAT), _vec(value["z"], 3, TYPE_FLOAT))
			return _from_str(value, TYPE_BASIS)
		TYPE_TRANSFORM2D:
			if typeof(value) == TYPE_DICTIONARY and value.has("origin"):
				return Transform2D(_vec(value.get("x", Vector2(1, 0)), 2, TYPE_FLOAT), _vec(value.get("y", Vector2(0, 1)), 2, TYPE_FLOAT), _vec(value["origin"], 2, TYPE_FLOAT))
			return _from_str(value, TYPE_TRANSFORM2D)
		TYPE_TRANSFORM3D:
			if typeof(value) == TYPE_DICTIONARY and value.has("basis"):
				var b: Variant = value["basis"]
				var basis_v: Basis = b if typeof(b) == TYPE_BASIS else Basis(_vec(b.get("x", Vector3(1, 0, 0)), 3, TYPE_FLOAT), _vec(b.get("y", Vector3(0, 1, 0)), 3, TYPE_FLOAT), _vec(b.get("z", Vector3(0, 0, 1)), 3, TYPE_FLOAT))
				return Transform3D(basis_v, _vec(value["origin"], 3, TYPE_FLOAT))
			return _from_str(value, TYPE_TRANSFORM3D)
		TYPE_PACKED_BYTE_ARRAY:
			if typeof(value) == TYPE_STRING:
				return Marshalls.base64_to_raw(value)
			return PackedByteArray(_vec(value, 1, TYPE_INT)) if typeof(value) == TYPE_ARRAY else PackedByteArray()
		TYPE_PACKED_STRING_ARRAY:
			return PackedStringArray(_str_array(value))
		TYPE_PACKED_INT32_ARRAY:
			return PackedInt32Array(_int_array(value))
		TYPE_PACKED_INT64_ARRAY:
			return PackedInt64Array(_int_array(value))
		TYPE_PACKED_FLOAT32_ARRAY:
			return PackedFloat32Array(_float_array(value))
		TYPE_PACKED_FLOAT64_ARRAY:
			return PackedFloat64Array(_float_array(value))
		TYPE_PACKED_VECTOR2_ARRAY:
			return PackedVector2Array(_vec_array(value, 2))
		TYPE_PACKED_VECTOR3_ARRAY:
			return PackedVector3Array(_vec_array(value, 3))
		TYPE_PACKED_COLOR_ARRAY:
			return PackedColorArray(_color_array(value))
		TYPE_PACKED_VECTOR4_ARRAY:
			return PackedVector4Array(_vec_array(value, 4))
		TYPE_ARRAY:
			return _to_plain(value)
		TYPE_DICTIONARY:
			return _to_plain(value)
		TYPE_OBJECT:
			return _object_ref(value, type_hint)
	return _auto(value)


static func _auto(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if is_nan(value) or is_inf(value):
				return value
			if is_equal_approx(value, round(value)):
				return int(value)
			return value
		TYPE_DICTIONARY:
			if value.has("$"):
				var tag: String = str(value["$"])
				match tag:
					"Vector2":
						return _vec(value, 2, TYPE_FLOAT)
					"Vector2i":
						return _vec(value, 2, TYPE_INT)
					"Vector3":
						return _vec(value, 3, TYPE_FLOAT)
					"Vector3i":
						return _vec(value, 3, TYPE_INT)
					"Vector4":
						return _vec(value, 4, TYPE_FLOAT)
					"Vector4i":
						return _vec(value, 4, TYPE_INT)
					"Color":
						return _color(value)
					"Rect2":
						var r := _vec(value, 4, TYPE_FLOAT)
						return Rect2(r[0], r[1], r[2], r[3])
					"Quaternion":
						var q := _vec(value, 4, TYPE_FLOAT)
						return Quaternion(q[0], q[1], q[2], q[3])
					"PackedStringArray":
						return PackedStringArray(_str_array(value.get("values", [])))
					"PackedInt32Array":
						return PackedInt32Array(_int_array(value.get("values", [])))
					"PackedFloat32Array":
						return PackedFloat32Array(_float_array(value.get("values", [])))
					"PackedByteArray":
						return Marshalls.base64_to_raw(str(value.get("base64", "")))
					"Transform2D":
						return Transform2D(_vec(value.get("x", Vector2(1, 0)), 2, TYPE_FLOAT), _vec(value.get("y", Vector2(0, 1)), 2, TYPE_FLOAT), _vec(value["origin"], 2, TYPE_FLOAT))
					"Resource", "Node", "Object", "ClassRef":
						return _object_ref(value, TYPE_OBJECT)
					"Signal", "Callable", "RID", "truncated":
						return value
			return _to_plain(value)
		TYPE_ARRAY:
			return _to_plain(value)
		TYPE_INT, TYPE_BOOL, TYPE_STRING:
			return value
	return value


const CTOR_TYPES := [
	"Vector2", "Vector2i", "Vector3", "Vector3i", "Vector4", "Vector4i", "Color", "Rect2", "Rect2i",
	"Plane", "Quaternion", "AABB", "Basis", "Transform2D", "Transform3D", "Projection", "StringName",
]


## Безопасный разбор строк вида "Vector2(1, 2)": без whitelist str_to_var() печатает ошибку.
static func parse_ctor(text: String) -> Variant:
	var t := text.strip_edges()
	var open := t.find("(")
	if open <= 0 or not t.ends_with(")"):
		return null
	var type_name := t.substr(0, open)
	if not CTOR_TYPES.has(type_name):
		return null
	return str_to_var(t)


static func _from_str(value: Variant, type_hint: int) -> Variant:
	if typeof(value) == TYPE_STRING:
		var parsed: Variant = parse_ctor(str(value))
		if typeof(parsed) == type_hint:
			return parsed
		if typeof(parsed) == TYPE_DICTIONARY:
			return coerce(parsed, type_hint)
	return value


static func _to_bool(value: Variant) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_INT, TYPE_FLOAT:
			return value != 0
		TYPE_STRING:
			var s := str(value).strip_edges().to_lower()
			return s in ["true", "1", "yes", "on", "да"]
	return false


static func _to_num(value: Variant) -> Variant:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			return value
		TYPE_BOOL:
			return 1 if value else 0
		TYPE_STRING:
			var s := str(value).strip_edges()
			if s.is_valid_int():
				return s.to_int()
			if s.is_valid_float():
				return s.to_float()
			var parsed: Variant = str_to_var(s)
			if typeof(parsed) == TYPE_INT or typeof(parsed) == TYPE_FLOAT:
				return parsed
	return 0


## Собирает вектор длиной n из dict {x,y,z,w}, массива или строки "Vector2(1, 2)".
static func _vec(value: Variant, n: int, kind: int) -> Variant:
	var src: Variant = value
	if typeof(src) == TYPE_DICTIONARY and src.has("$") and not src.has("x"):
		src = null
	if typeof(src) == TYPE_STRING:
		var parsed: Variant = parse_ctor(str(src))
		if typeof(parsed) == TYPE_VECTOR2 or typeof(parsed) == TYPE_VECTOR2I \
				or typeof(parsed) == TYPE_VECTOR3 or typeof(parsed) == TYPE_VECTOR3I \
				or typeof(parsed) == TYPE_VECTOR4 or typeof(parsed) == TYPE_VECTOR4I \
				or typeof(parsed) == TYPE_COLOR or typeof(parsed) == TYPE_RECT2 or typeof(parsed) == TYPE_RECT2I \
				or typeof(parsed) == TYPE_QUATERNION or typeof(parsed) == TYPE_PLANE:
			src = parsed
	var comps: Array = []
	if typeof(src) == TYPE_DICTIONARY:
		var keys := ["x", "y", "z", "w", "r", "g", "b", "a"]
		for i2: int in range(n):
			var key: String = keys[i2]
			comps.append(float(_to_num(src.get(key, 0.0))) if kind == TYPE_FLOAT else int(_to_num(src.get(key, 0))))
	elif typeof(src) == TYPE_ARRAY:
		for i3: int in range(n):
			comps.append(float(_to_num(src[i3] if i3 < src.size() else 0)) if kind == TYPE_FLOAT else int(_to_num(src[i3] if i3 < src.size() else 0)))
	else:
		var flat := [0.0, 0.0, 0.0, 0.0]
		if src is Rect2:
			flat = [src.position.x, src.position.y, src.size.x, src.size.y]
		elif src is Rect2i:
			flat = [float(src.position.x), float(src.position.y), float(src.size.x), float(src.size.y)]
		elif src is Color:
			flat = [src.r, src.g, src.b, src.a]
		for i4: int in range(n):
			comps.append(float(flat[i4]) if kind == TYPE_FLOAT else int(flat[i4]))
	var is_int := kind == TYPE_INT
	match n:
		2:
			return Vector2i(int(comps[0]), int(comps[1])) if is_int else Vector2(float(comps[0]), float(comps[1]))
		3:
			return Vector3i(int(comps[0]), int(comps[1]), int(comps[2])) if is_int else Vector3(float(comps[0]), float(comps[1]), float(comps[2]))
		4:
			if is_int:
				return Vector4i(int(comps[0]), int(comps[1]), int(comps[2]), int(comps[3]))
			return Vector4(float(comps[0]), float(comps[1]), float(comps[2]), float(comps[3]))
	return 0


static func _color(value: Variant) -> Color:
	if typeof(value) == TYPE_COLOR:
		return value
	if typeof(value) == TYPE_STRING:
		var s := str(value).strip_edges()
		if s.begins_with("#"):
			return Color.from_string(s, Color(0, 0, 0, 1))
		var parsed: Variant = str_to_var(s)
		if typeof(parsed) == TYPE_COLOR:
			return parsed
	if typeof(value) == TYPE_DICTIONARY:
		if value.has("hex"):
			return Color.from_string(str(value["hex"]), Color(0, 0, 0, 1))
		var keys := ["r", "g", "b", "a"]
		var comps := []
		for k: String in keys:
			comps.append(float(_to_num(value.get(k, k == "a" and 1.0 or 0.0))))
		return Color(comps[0], comps[1], comps[2], comps[3])
	return Color(0, 0, 0, 1)


## Ссылка на объект: путь к ресурсу, имя класса, uid или null-инстанс.
static func _object_ref(value: Variant, _type_hint: int) -> Variant:
	if value == null:
		return null
	if typeof(value) == TYPE_STRING:
		var s := str(value)
		if s == "" or s == "null":
			return null
		if s.begins_with("uid://"):
			var uid_path := ResourceUID.get_id_path(ResourceUID.text_to_id(s))
			if uid_path != "" and ResourceLoader.exists(uid_path):
				return ResourceLoader.load(uid_path)
			return null
		if ResourceLoader.exists(s):
			return ResourceLoader.load(s)
		if ClassDB.class_exists(s) and ClassDB.can_instantiate(s):
			return ClassDB.instantiate(s)
		return null
	if typeof(value) == TYPE_OBJECT:
		return value
	if typeof(value) == TYPE_DICTIONARY:
		if value.has("path"):
			var p := str(value["path"])
			if p != "" and ResourceLoader.exists(p):
				return ResourceLoader.load(p)
			if str(value.get("$", "")) == "ClassRef" and ClassDB.class_exists(str(value.get("class", ""))):
				return ClassDB.instantiate(str(value["class"]))
		if value.has("class"):
			var cname := str(value["class"])
			if ClassDB.class_exists(cname) and ClassDB.can_instantiate(cname):
				return ClassDB.instantiate(cname)
	return null


static func _to_plain(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var out := {}
			for k: Variant in value:
				out[_key(k)] = _auto(value[k])
			return out
		TYPE_ARRAY:
			var arr := []
			for item: Variant in value:
				arr.append(_auto(item))
			return arr
	return _auto(value)


static func _str_array(value: Variant) -> Array:
	var out := []
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			out.append(str(item))
	elif typeof(value) == TYPE_PACKED_STRING_ARRAY:
		for item: Variant in value:
			out.append(str(item))
	elif typeof(value) == TYPE_DICTIONARY and typeof(value.get("values")) == TYPE_ARRAY:
		for item: Variant in value["values"]:
			out.append(str(item))
	return out


static func _int_array(value: Variant) -> Array:
	var out := []
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			out.append(int(_to_num(item)))
	elif typeof(value) == TYPE_DICTIONARY and typeof(value.get("values")) == TYPE_ARRAY:
		for item: Variant in value["values"]:
			out.append(int(_to_num(item)))
	return out


static func _float_array(value: Variant) -> Array:
	var out := []
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			out.append(float(_to_num(item)))
	elif typeof(value) == TYPE_DICTIONARY and typeof(value.get("values")) == TYPE_ARRAY:
		for item: Variant in value["values"]:
			out.append(float(_to_num(item)))
	return out


static func _vec_array(value: Variant, n: int) -> Array:
	var out := []
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			out.append(_vec(item, n, TYPE_FLOAT))
	elif typeof(value) == TYPE_DICTIONARY and typeof(value.get("values")) == TYPE_ARRAY:
		for item: Variant in value["values"]:
			out.append(_vec(item, n, TYPE_FLOAT))
	return out


static func _color_array(value: Variant) -> Array:
	var out := []
	if typeof(value) == TYPE_ARRAY:
		for item: Variant in value:
			out.append(_color(item))
	elif typeof(value) == TYPE_DICTIONARY and typeof(value.get("values")) == TYPE_ARRAY:
		for item: Variant in value["values"]:
			out.append(_color(item))
	return out

@warning_ignore_restore("inference_on_variant")
