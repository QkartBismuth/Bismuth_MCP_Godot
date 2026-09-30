
@warning_ignore_start("inference_on_variant")
extends RefCounted
# Захват кадра: PNG из окна или SubViewport, с опциональным кропом по узлу.

const V := preload("res://.mcp/variant.gd")
const SHOT_DIR := "res://.mcp-shots"

var host


## Обёртка над оператором %: GDScript-парсер спотыкается о "% [...]" внутри словарей.
static func fmt(template: String, args: Array) -> String:
	return template % args


func commands() -> PackedStringArray:
	return PackedStringArray(["capture.screenshot", "capture.resource_image"])


func _screenshot(p: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless":
		return host.err(
			"Скриншот недоступен: хост запущен в headless-режиме (--display-driver headless использует фиктивный рендерер). "
			+ "Запустите игру с godot_run { render: true } — тогда Godot стартует с реальным display-драйвером.",
			"no_renderer"
		)
	var id: int = host.current_id
	var params := p
	host.defer_response(id, func() -> void: _deliver(id, params))
	return {"deferred": true}


## Выполняется на следующем кадре, когда предыдущий уже отрендерен.
func _deliver(id: int, p: Dictionary) -> void:
	var target := str(p.get("path", ""))
	if target.is_empty():
		target = SHOT_DIR.path_join("shot_%d.png" % Time.get_ticks_msec())
	var res_path: String = host.safe_res_path(target)
	DirAccess.make_dir_recursive_absolute(res_path.get_base_dir())

	RenderingServer.force_draw()
	var source: Viewport = null
	var node_path := str(p.get("node", ""))
	if not node_path.is_empty():
		var node: Node = host.find_node(host.runtime_base(), node_path)
		if node == null:
			host.respond(id, host.err("Узел для кропа не найден: %s" % node_path, "node_not_found"))
			return
		source = _viewport_of(node)
		if source == null:
			host.respond(id, host.err("Не удалось определить Viewport для узла %s" % node_path, "no_viewport"))
			return
	else:
		source = host.root
	var tex := source.get_texture()
	if tex == null:
		host.respond(id, host.err("Viewport не имеет текстуры", "no_texture"))
		return
	var img := tex.get_image()
	if img == null or img.is_empty():
		host.respond(id, host.err("Получен пустой кадр (окно ещё не отрисовано?)", "empty_image"))
		return
	var cropped := false
	if not node_path.is_empty():
		var node2: Node = host.find_node(host.runtime_base(), node_path)
		var rect := _node_rect(node2, source)
		if rect.size.x > 1 and rect.size.y > 1:
			img = img.get_region(Rect2i(rect).intersection(Rect2i(Vector2i.ZERO, img.get_size())))
			cropped = true
	var scale_factor := float(p.get("scale", 0.0))
	if scale_factor > 0.0:
		img.resize(int(img.get_width() * scale_factor), int(img.get_height() * scale_factor), Image.INTERPOLATE_BILINEAR)
	var err := img.save_png(res_path)
	if err != OK:
		host.respond(id, host.err("Не удалось сохранить PNG: %s" % error_string(err), "save_error"))
		return
	host.respond(id, host.ok({
		"path": res_path,
		"real_path": ProjectSettings.globalize_path(res_path),
		"size": {"width": img.get_width(), "height": img.get_height()},
		"cropped": cropped,
		"source": str(source.get_path()) if source is Node else "viewport",
		"bytes": FileAccess.get_size(res_path),
	}))


func _viewport_of(node: Node) -> Viewport:
	if node is Viewport:
		return node
	var vp := node.get_viewport()
	return vp


## Прямоугольник узла в пикселях Viewport.
func _node_rect(node: Node, viewport: Viewport) -> Rect2:
	if node is Control:
		var c: Control = node
		return _transform_rect(c.get_global_rect(), c.get_global_transform_with_canvas())
	if node is Node2D:
		var n: Node2D = node
		var rect := _node2d_rect(n)
		return _transform_rect(rect, n.get_global_transform_with_canvas())
	if node is Node3D:
		var n3: Node3D = node
		var cam := viewport.get_camera_3d()
		if cam == null:
			return Rect2()
		var aabb: AABB = n3.get_aabb()
		var corners := [
			cam.unproject_position(aabb.position),
			cam.unproject_position(aabb.position + Vector3(aabb.size.x, 0, 0)),
			cam.unproject_position(aabb.position + Vector3(0, aabb.size.y, 0)),
			cam.unproject_position(aabb.position + aabb.size),
		]
		var minp: Vector2 = corners[0]
		var maxp: Vector2 = corners[0]
		for c: Vector2 in corners:
			minp = minp.min(c)
			maxp = maxp.max(c)
		return Rect2(minp.floor(), (maxp - minp).ceil())
	return Rect2()


## Локальный прямоугольник Node2D: объединение rect'ов потомков (у спрайтов есть get_rect()).
func _node2d_rect(node: Node2D) -> Rect2:
	var rect := Rect2()
	var found := false
	for child: Node in node.get_children():
		if child.has_method("get_rect"):
			var r: Rect2 = child.call("get_rect")
			if r.size.x <= 0.0 or r.size.y <= 0.0:
				continue
			rect = rect.merge(r) if found else r
			found = true
	if found:
		return rect.grow(8.0)
	return Rect2(Vector2(-32, -32), Vector2(64, 64))


func _transform_rect(rect: Rect2, xform: Transform2D) -> Rect2:
	var points := [
		xform * rect.position,
		xform * (rect.position + Vector2(rect.size.x, 0)),
		xform * (rect.position + Vector2(0, rect.size.y)),
		xform * (rect.position + rect.size),
	]
	var minp: Vector2 = points[0]
	var maxp: Vector2 = points[0]
	for p: Vector2 in points:
		minp = minp.min(p)
		maxp = maxp.max(p)
	return Rect2(minp.floor(), (maxp - minp).ceil())


func handle(cmd: String, p: Dictionary) -> Dictionary:
	if cmd == "capture.screenshot":
		return _screenshot(p)
	if cmd == "capture.resource_image":
		return _resource_image(p)
	return host.err("Команда не реализована в capture: %s" % cmd, "not_implemented")


## Конвертирует текстуру проекта в PNG (работает и в headless — чтение пикселей не требует GPU).
func _resource_image(p: Dictionary) -> Dictionary:
	var res_path: String = host.safe_res_path(str(p.get("path", "")))
	if not ResourceLoader.exists(res_path):
		return host.err("Ресурс не найден: %s" % res_path, "not_found")
	var res: Resource = ResourceLoader.load(res_path)
	var img: Image = null
	if res is Texture2D:
		img = (res as Texture2D).get_image()
	elif res is Image:
		img = (res as Image).duplicate()
	if img == null:
		return host.err(fmt("Ресурс не является текстурой: %s (%s)", [res_path, res.get_class()]), "wrong_type")
	if img.is_empty():
		return host.err("Изображение пустое: %s" % res_path, "empty_image")
	var size := int(p.get("size", 0))
	if size > 0:
		img.resize(size, size, Image.INTERPOLATE_LANCZOS)
	var out := str(p.get("out", ""))
	if out.is_empty():
		out = SHOT_DIR.path_join("asset_%d.png" % Time.get_ticks_msec())
	var out_path: String = host.safe_res_path(out)
	DirAccess.make_dir_recursive_absolute(out_path.get_base_dir())
	var err := img.save_png(out_path)
	if err != OK:
		return host.err("Не удалось сохранить PNG: %s" % error_string(err), "save_error")
	return {
		"path": out_path,
		"real_path": ProjectSettings.globalize_path(out_path),
		"source": res_path,
		"source_class": res.get_class(),
		"image": {"width": img.get_width(), "height": img.get_height(), "format": str(img.get_format())},
		"bytes": FileAccess.get_size(out_path),
	}

@warning_ignore_restore("inference_on_variant")
