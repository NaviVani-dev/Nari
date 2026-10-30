extends Control

const BLOB_COUNT := 14
const TRIANGLE_COUNT := 18
const QUALITY_FPS := {"high": 60, "medium": 30, "low": 15}
const BLOB_PARAMS := ["speed", "frequency", "movement_variation", "blob_size", "size_variation", "color_variation", "intensity"]
const TRIANGLE_PARAMS := ["speed", "movement_variation", "triangle_size", "size_variation", "width_variation", "height_variation", "rotation_speed", "rotation_variation", "opacity", "frequency"]
const COVER_BLUR_SIZE := 24
const DARK_DOTS_OPACITY := 0.07
const STAGE_TIME := 0.6
const CLOCK_EASE := 4.0
const SHADER_SCALE := 2
const LOW_RES := ["color", "blobs", "tint", "shader"]
const FITS := {"cover": TextureRect.STRETCH_KEEP_ASPECT_COVERED, "contain": TextureRect.STRETCH_KEEP_ASPECT_CENTERED, "stretch": TextureRect.STRETCH_SCALE, "tile": TextureRect.STRETCH_TILE}
const TRIANGLE_REACH := 1.3
const TRIANGLE_RECT := Rect2(-1.0, -1.0, 2.0, 2.0)
const BLOBS_SHADER := preload("res://assets/shaders/gradientblobs.gdshader")
const TRIANGLES_SHADER := preload("res://assets/shaders/triangles.gdshader")
const DOTS_SHADER := preload("res://assets/shaders/dots.gdshader")
const BLOB_DEFAULTS := {
	"background_color": Color.WHITE, "speed": 0.05, "direction": Vector2(1.5, -1.0), "movement_variation": 0.4,
	"blob_size": 0.25, "size_variation": 0.35, "softness": 1.4, "frequency": 1.0, "color_variation": 0.08,
	"intensity": 0.75, "opacity": 0.25,
}
const TRIANGLE_DEFAULTS := {
	"speed": 0.03, "direction": Vector2(5.0, -1.5), "movement_variation": 1.5, "triangle_size": 0.085,
	"size_variation": 0.75, "width_variation": 0.35, "height_variation": 0.2, "rotation_speed": 0.08,
	"rotation_variation": 0.7, "frequency": 1.65, "opacity": 0.25,
}
const DOT_DEFAULTS := {"dot_color": Color.WHITE, "dot_size": 18.0, "spacing": 4.32, "opacity": 0.25, "offset": Vector2.ZERO}
const TINT_COLORS := [Color(1.0, 1.0, 1.0, 0.3), Color(1.0, 1.0, 1.0, 0.2)]

@export_range(1, 16) var background_scale: int = 16

var _views: Array[SubViewport] = []
var _colors: Array[ColorRect] = []
var _tints: Array[TextureRect] = []
var _blob_mats: Array[ShaderMaterial] = []
var _triangle_layers: Array[Control] = []
var _dot_mats: Array[ShaderMaterial] = []
var _shader_layers: Array[Dictionary] = []
var _media_layers: Array[Dictionary] = []
var _visible_by_page: Array[Dictionary] = []
var _tint_texture := GradientTexture2D.new()
var _time := 0.0
var _quality_fps := 0
var _quality_elapsed := 0.0
var _blob_shape := PackedVector4Array()
var _blob_tint := PackedVector4Array()
var _triangle_xforms: Array[Transform2D] = []
var _triangle_colors := PackedColorArray()
var _triangle_count := 0
var _blob_params := {}
var _triangle_params := {}
var _palette: Array = []
var _cover: Texture2D
var _cover_key := ""
var _animated := true
var _mode := "full"
var _stage_tween: Tween

func _ready() -> void:
	var gradient := Gradient.new()
	gradient.colors = PackedColorArray(TINT_COLORS)
	_tint_texture.gradient = gradient
	_tint_texture.fill_to = Vector2(0, 1)
	_blob_shape.resize(BLOB_COUNT)
	_blob_tint.resize(BLOB_COUNT)
	_triangle_xforms.resize(TRIANGLE_COUNT)
	_triangle_colors.resize(TRIANGLE_COUNT)
	_blob_params = BLOB_DEFAULTS.duplicate()
	_blob_params.offset = _seed_offset(randf_range(0.0, 10000.0))
	_blob_params.flow = (BLOB_DEFAULTS["direction"] as Vector2).normalized()
	_triangle_params = TRIANGLE_DEFAULTS.duplicate()
	_triangle_params.offset = _seed_offset(randf_range(0.0, 10000.0))
	_triangle_params.flow = (TRIANGLE_DEFAULTS["direction"] as Vector2).normalized()
	_apply_quality(SettingsManager.performance.background_quality)
	_mode = str(SettingsManager.performance.background)
	resized.connect(_resize)
	ThemeEngine.follow(self, _update_appearance)
	Themes.backgrounds_changed.connect(_build)
	Themes.stage_changed.connect(_restage)
	Main.page_changed.connect(_refresh_pages.unbind(2))
	MediaPlayer.playback_changed.connect(_refresh_cover.unbind(1))
	SettingsManager.changed.connect(func(section: String, key: String, value: Variant):
		if section != "performance":
			return
		if key == "background":
			_mode = str(value)
			_build()
		elif key == "background_quality":
			_apply_quality(value))
	_build()

func _process(delta: float) -> void:
	var host := get_viewport()
	if host is SubViewport and host.render_target_update_mode == SubViewport.UPDATE_DISABLED or host is Window and not host.visible:
		return
	_time += delta
	_tick_clocks(delta)
	if _quality_fps > 0:
		_quality_elapsed += delta
		if _quality_elapsed < 1.0 / float(_quality_fps):
			return
		_quality_elapsed = fmod(_quality_elapsed, 1.0 / float(_quality_fps))
	_redraw()

func _apply_quality(quality: Variant) -> void:
	_quality_fps = QUALITY_FPS.get(str(quality), 0)
	_quality_elapsed = 0.0

func _build() -> void:
	if _stage_tween:
		_stage_tween.kill()
	for child in get_children():
		child.queue_free()
	for list: Array in [_views, _colors, _tints, _blob_mats, _triangle_layers, _dot_mats, _shader_layers, _media_layers, _visible_by_page]:
		list.clear()
	_animated = _mode != "simple"
	var view: SubViewport = null
	var group_key := ""
	for layer in _screen_layers():
		var kind := str(layer["type"])
		if not _wanted(kind):
			continue
		var node := _layer_node(layer)
		if node == null:
			continue
		if kind in LOW_RES:
			var key := _group_key(layer)
			if view == null or key != group_key:
				view = _new_view(layer)
				group_key = key
			view.add_child(node)
		else:
			view = null
			add_child(node)
		_visible_by_page.append({"node": node, "layer": layer})
	_refresh_pages()
	_refresh_cover()
	_resize()
	_update_appearance()
	set_process(not _blob_mats.is_empty() or not _triangle_layers.is_empty() or _animated and not _shader_layers.is_empty())

func _screen_layers() -> Array:
	var screen := Themes.screen_of(self)
	return Themes.layers.filter(func(layer: Dictionary) -> bool: return Themes.shows_on_screen(layer, screen))

func _wanted(kind: String) -> bool:
	match kind:
		"blobs":
			return _animated
		"triangles":
			return _animated and _mode != "gradient"
	return true

func _group_key(layer: Dictionary) -> String:
	if str(layer["type"]) != "shader":
		return "base"
	return "%d:%s" % [int(layer.get("scale", SHADER_SCALE)), str(layer.get("filter", ""))]

func _new_view(layer: Dictionary) -> SubViewport:
	var holder := SubViewportContainer.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.stretch = true
	var shader := str(layer["type"]) == "shader"
	holder.stretch_shrink = maxi(int(layer.get("scale", SHADER_SCALE)), 1) if shader else background_scale
	if shader and str(layer.get("filter", "")) == "nearest":
		holder.texture_filter = TEXTURE_FILTER_NEAREST
	var view := SubViewport.new()
	if "disable_3d" in view:
		view.set("disable_3d", true)
	view.transparent_bg = true
	view.handle_input_locally = false
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	holder.add_child(view)
	add_child(holder)
	_views.append(view)
	return view

func _filled(node: Control) -> Control:
	node.set_anchors_preset(Control.PRESET_FULL_RECT)
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.modulate.a = clampf(float(node.get_meta("opacity", 1.0)), 0.0, 1.0)
	return node

func _layer_node(layer: Dictionary) -> Control:
	match str(layer["type"]):
		"color":
			var rect := ColorRect.new()
			if layer.has("color"):
				rect.set_meta("paint", layer["color"])
			_colors.append(rect)
			return _filled(rect)
		"tint":
			var rect := TextureRect.new()
			rect.texture = _tint_texture
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			_tints.append(rect)
			return _filled(rect)
		"blobs":
			var rect := ColorRect.new()
			rect.material = _material(BLOBS_SHADER, BLOB_DEFAULTS)
			_blob_mats.append(rect.material)
			return _filled(rect)
		"triangles":
			var shapes := Control.new()
			shapes.material = _material(TRIANGLES_SHADER, TRIANGLE_DEFAULTS)
			shapes.draw.connect(_draw_triangles.bind(shapes))
			_triangle_layers.append(shapes)
			return _filled(shapes)
		"dots":
			var rect := ColorRect.new()
			rect.color = Color(1.0, 1.0, 1.0, 0.0)
			var dots := _material(DOTS_SHADER, DOT_DEFAULTS)
			var color := str(layer.get("color", ""))
			dots.set_shader_parameter("dot_color", Color.html(color) if Color.html_is_valid(color) else Color.WHITE)
			dots.set_shader_parameter("opacity", DARK_DOTS_OPACITY if ThemeEngine.dark_mode else float(DOT_DEFAULTS["opacity"]))
			rect.material = dots
			_dot_mats.append(dots)
			return _filled(rect)
		"shader":
			var shader := Themes.shader_of(str(layer.get("file", "")))
			if shader == null:
				return null
			var rect := ColorRect.new()
			var material := ShaderMaterial.new()
			material.shader = shader
			rect.material = material
			var uniforms: Variant = layer.get("uniforms", {})
			var entry := {"material": material, "uniforms": (uniforms as Dictionary).duplicate() if uniforms is Dictionary else {}, "clocks": {}, "layer": layer}
			_wind_clocks(entry, layer.get("clocks", {}))
			_shader_layers.append(entry)
			rect.set_meta("opacity", layer.get("opacity", 1.0))
			return _filled(rect)
		"image", "cover":
			var rect := TextureRect.new()
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = FITS.get(str(layer.get("fit", "cover")), TextureRect.STRETCH_KEEP_ASPECT_COVERED)
			var file := str(layer.get("file", ""))
			rect.texture = Themes.texture_of(file) if layer["type"] == "image" else _cover
			rect.texture_filter = Themes.filter_of(file)
			if layer["type"] == "image":
				Themes.watch(file, rect)
			var dim := ColorRect.new()
			rect.add_child(_filled(dim))
			rect.set_meta("opacity", layer.get("opacity", 1.0))
			_media_layers.append({"node": rect, "dim": dim, "layer": layer})
			return _filled(rect)
	return null

func _material(shader: Shader, defaults: Dictionary) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = shader
	for key: String in defaults:
		material.set_shader_parameter(key, defaults[key])
	return material

func _refresh_pages() -> void:
	var page := Themes.current_page()
	for entry in _visible_by_page:
		var node: Control = entry["node"]
		var shown := Themes.shows_on(entry["layer"], page)
		if entry["layer"]["type"] == "cover":
			shown = shown and _cover != null
		elif entry["layer"]["type"] == "image":
			shown = shown and node.texture != null
		node.visible = shown
	_redraw()

func _refresh_cover() -> void:
	if not _media_layers.any(func(entry: Dictionary): return entry["layer"]["type"] == "cover"):
		_cover = null
		_cover_key = ""
		return
	var cover := MediaPlayer.cover_of(MediaPlayer.get_current_song())
	var key := "%s:%s" % cover
	if key == _cover_key:
		return
	_cover_key = key
	var image: Image = await MediaPlayer.get_cover_image(cover[0], cover[1], true)
	if key != _cover_key:
		return
	if image:
		image = image.duplicate()
		if image.is_compressed():
			image.decompress()
		image.resize(COVER_BLUR_SIZE, COVER_BLUR_SIZE, Image.INTERPOLATE_BILINEAR)
	_cover = ImageTexture.create_from_image(image) if image else null
	for entry in _media_layers:
		if entry["layer"]["type"] == "cover":
			entry["node"].texture = _cover
	_refresh_pages()

func _restage() -> void:
	if _stage_tween:
		_stage_tween.kill()
	var fresh := _screen_layers().filter(func(layer: Dictionary): return _wanted(str(layer["type"])))
	var shaders := fresh.filter(func(layer: Dictionary): return layer["type"] == "shader" and Themes.shader_of(str(layer.get("file", ""))) != null)
	var media := fresh.filter(func(layer: Dictionary): return layer["type"] in ["image", "cover"])
	if shaders.size() != _shader_layers.size() or media.size() != _media_layers.size():
		_build()
		return
	for index in media.size():
		_media_layers[index]["layer"] = media[index]
	var starts: Array[Dictionary] = []
	var targets: Array[Dictionary] = []
	var duration := 0.0
	for index in shaders.size():
		var entry := _shader_layers[index]
		var layer: Dictionary = shaders[index]
		entry["layer"] = layer
		_wind_clocks(entry, layer.get("clocks", {}))
		starts.append((entry["uniforms"] as Dictionary).duplicate())
		var uniforms: Variant = layer.get("uniforms", {})
		targets.append(uniforms if uniforms is Dictionary else {})
		duration = maxf(duration, float(layer.get("transition", STAGE_TIME)))
	_rebind_pages()
	if Main.reduce_motion or duration <= 0.0:
		for index in targets.size():
			_shader_layers[index]["uniforms"] = targets[index].duplicate()
		_update_appearance()
		return
	for index in targets.size():
		for uniform: String in targets[index]:
			if _drives_clock(_shader_layers[index], uniform):
				_shader_layers[index]["uniforms"][uniform] = targets[index][uniform]
	_stage_tween = create_tween()
	_stage_tween.tween_method(func(weight: float):
		for index in targets.size():
			var entry := _shader_layers[index]
			for uniform: String in targets[index]:
				if _drives_clock(entry, uniform):
					continue
				var from: Variant = starts[index].get(uniform)
				var to: Variant = targets[index][uniform]
				var numbers := (from is float or from is int) and (to is float or to is int)
				entry["uniforms"][uniform] = lerpf(from, to, weight) if numbers else to
		_update_appearance(), 0.0, 1.0, duration)

func _rebind_pages() -> void:
	var fresh := _screen_layers().filter(func(layer: Dictionary): return _wanted(str(layer["type"])))
	var index := 0
	for entry in _visible_by_page:
		while index < fresh.size() and fresh[index]["type"] != entry["layer"]["type"]:
			index += 1
		if index < fresh.size():
			entry["layer"] = fresh[index]
			index += 1
	_refresh_pages()

func _wind_clocks(entry: Dictionary, listed: Variant) -> void:
	var previous: Dictionary = entry["clocks"]
	var clocks := {}
	if listed is Dictionary:
		for clock: Variant in listed:
			var config: Dictionary = listed[clock] if listed[clock] is Dictionary else {"rate": str(listed[clock])}
			var rate := str(config.get("rate", ""))
			if rate.is_empty():
				continue
			var pace := float(Themes.uniform_value(entry["uniforms"].get(rate, 0.0)))
			var state: Dictionary = previous.get(clock, {"time": 0.0, "pace": pace})
			state.merge({
				"rate": rate,
				"speed_up": float(config.get("speed_up", CLOCK_EASE)),
				"slow_down": float(config.get("slow_down", CLOCK_EASE)),
				"settle": float(config.get("settle", 0.0)),
			}, true)
			clocks[str(clock)] = state
	entry["clocks"] = clocks

func _drives_clock(entry: Dictionary, uniform: String) -> bool:
	return entry["clocks"].values().any(func(clock: Dictionary): return clock["rate"] == uniform)

func _tick_clocks(delta: float) -> void:
	for entry in _shader_layers:
		for clock: String in entry["clocks"]:
			var state: Dictionary = entry["clocks"][clock]
			var target := float(Themes.uniform_value(entry["uniforms"].get(state["rate"], 0.0)))
			var pace: float = state["pace"]
			if Main.reduce_motion:
				pace = target
			var step := minf(delta * float(state["slow_down"] if pace > target else state["speed_up"]), 1.0)
			pace = lerpf(pace, target, step)
			state["pace"] = pace
			state["time"] = float(state["time"]) + delta * pace - float(state["settle"]) * (target - pace) * step
			entry["material"].set_shader_parameter(clock, state["time"])
			entry["material"].set_shader_parameter(state["rate"], pace)

func _redraw() -> void:
	if _palette.size() < 3:
		_palette = _theme_palette()
	if not _blob_mats.is_empty():
		_update_blobs()
	if not _triangle_layers.is_empty():
		_update_triangles()
		for shapes in _triangle_layers:
			shapes.queue_redraw()
	for view in _views:
		view.render_target_update_mode = SubViewport.UPDATE_ONCE

func _resize() -> void:
	for view in _views:
		var holder := view.get_parent() as SubViewportContainer
		var render_size := size / float(holder.stretch_shrink)
		for child in view.get_children():
			if child is CanvasItem and (child as CanvasItem).material is ShaderMaterial:
				((child as CanvasItem).material as ShaderMaterial).set_shader_parameter("rect_size", render_size)
	for dots in _dot_mats:
		dots.set_shader_parameter("rect_size", size)
	_redraw()

func _hash(value: float, offset: float, amount: float = 1.0) -> float:
	var noise := sin((value + offset) * amount) * 43758.5453123
	return noise - floorf(noise)

func _seed_offset(value: float) -> float:
	return value * 173.137 + sin(value * 91.7) * 53.31

func _update_blobs() -> void:
	var offset: float = _blob_params.offset
	var speed: float = _blob_params.speed
	var frequency: float = _blob_params.frequency
	var movement_variation: float = _blob_params.movement_variation
	var blob_size: float = _blob_params.blob_size
	var size_variation: float = _blob_params.size_variation
	var color_variation: float = _blob_params.color_variation
	var intensity: float = _blob_params.intensity
	var palette := _palette
	var flow: Vector2 = _blob_params.flow
	var side := Vector2(-flow.y, flow.x)

	for index in BLOB_COUNT:
		var blob_seed := index * 37.719
		var lifetime := _time * speed * frequency + _hash(blob_seed * 3.13, offset)
		var cycle := floorf(lifetime)
		var progress := lifetime - cycle
		var cycle_seed := blob_seed + cycle * 51.135
		var deviation := (_hash(cycle_seed * 9.91, offset) - 0.5) * movement_variation
		var heading := (flow + side * deviation).normalized()
		var lateral := (_hash(cycle_seed * 12.9898, offset) - 0.5) * 2.0
		var wobble := sin(_time * 0.35 + cycle_seed) * 0.07 * movement_variation
		var center := Vector2(0.5, 0.5) + heading * (progress * 2.4 - 1.2) + side * (lateral + wobble)
		var radius := maxf(blob_size * lerpf(1.0 - size_variation, 1.0 + size_variation, _hash(cycle_seed * 15.31, offset)), 0.001)
		var stretch_x := lerpf(0.75, 1.35, _hash(cycle_seed * 2.33 * 12.9898, offset))
		var stretch_y := lerpf(0.75, 1.35, _hash(cycle_seed * 2.33 * 78.233, offset))
		var strength := smoothstep(0.0, 0.15, progress) * (1.0 - smoothstep(0.75, 1.0, progress)) * intensity
		var selector := _hash(cycle_seed * 5.37, offset)
		var base: Color = palette[0] if selector < 0.333333 else (palette[1] if selector < 0.666666 else palette[2])
		var shade := (Vector3(base.r, base.g, base.b) + Vector3(
			_hash(cycle_seed * 8.71 * 17.17, offset) - 0.5,
			_hash(cycle_seed * 8.71 * 31.31, offset) - 0.5,
			_hash(cycle_seed * 8.71 * 47.47, offset) - 0.5
		) * color_variation).clamp(Vector3.ZERO, Vector3.ONE)
		_blob_shape[index] = Vector4(center.x, center.y, stretch_x / radius, stretch_y / radius)
		_blob_tint[index] = Vector4(shade.x, shade.y, shade.z, strength)

	for material in _blob_mats:
		material.set_shader_parameter("blob_shape", _blob_shape)
		material.set_shader_parameter("blob_tint", _blob_tint)
		material.set_shader_parameter("blob_count", BLOB_COUNT)

func _update_triangles() -> void:
	var offset: float = _triangle_params.offset
	var speed: float = _triangle_params.speed
	var movement_variation: float = _triangle_params.movement_variation
	var triangle_size: float = _triangle_params.triangle_size
	var size_variation: float = _triangle_params.size_variation
	var width_variation: float = _triangle_params.width_variation
	var height_variation: float = _triangle_params.height_variation
	var rotation_speed: float = _triangle_params.rotation_speed
	var rotation_variation: float = _triangle_params.rotation_variation
	var opacity: float = _triangle_params.opacity
	var spawn_chance := clampf(float(_triangle_params.frequency) * 0.55, 0.05, 1.0)
	var palette := _palette
	var flow: Vector2 = _triangle_params.flow
	var side := Vector2(-flow.y, flow.x)
	var height := size.y
	var origin := Vector2((size.x - height) * 0.5, 0.0)
	var count := 0

	for index in TRIANGLE_COUNT:
		var triangle_seed := index * 41.713
		var life := _time * speed + _hash(triangle_seed * 3.71, offset, 127.1)
		var cycle := floorf(life)
		var progress := life - cycle
		var cycle_seed := triangle_seed + cycle * 53.117
		if _hash(cycle_seed * 9.73, offset, 127.1) > spawn_chance:
			continue
		var deviation := (_hash(cycle_seed * 6.31, offset, 127.1) - 0.5) * movement_variation
		var heading := (flow + side * deviation).normalized()
		var lateral := (_hash(cycle_seed * 11.19, offset, 127.1) - 0.5) * 2.25
		var drift := sin(_time * 0.18 + cycle_seed) * 0.035 * movement_variation
		var center := Vector2(0.5, 0.5) + heading * (progress * 2.7 - 1.35) + side * (lateral + drift)
		var radius := triangle_size * lerpf(1.0 - size_variation, 1.0 + size_variation, _hash(cycle_seed * 15.91, offset, 127.1))
		var spin := rotation_speed * lerpf(1.0 - rotation_variation, 1.0 + rotation_variation, _hash(cycle_seed * 37.13, offset, 127.1))
		var way := 1.0 if _hash(cycle_seed * 29.71, offset, 127.1) >= 0.5 else -1.0
		var angle := _hash(cycle_seed * 21.31, offset, 127.1) * TAU + _time * spin * way
		var width_scale := maxf(lerpf(1.0 - width_variation, 1.0 + width_variation, _hash(cycle_seed * 43.71, offset, 127.1)), 0.05)
		var height_scale := maxf(lerpf(1.0 - height_variation, 1.0 + height_variation, _hash(cycle_seed * 61.93, offset, 127.1)), 0.05)
		var alpha := smoothstep(0.0, 0.08, progress) * (1.0 - smoothstep(0.90, 1.0, progress)) * opacity
		var selector := _hash(cycle_seed * 7.13, offset, 127.1)
		var color: Color = palette[0] if selector < 0.333333 else (palette[1] if selector < 0.666666 else palette[2])
		_triangle_xforms[count] = Transform2D(angle, Vector2(width_scale, height_scale) * radius * height * TRIANGLE_REACH, 0.0, origin + center * height)
		_triangle_colors[count] = Color(color, alpha)
		count += 1
	_triangle_count = count

func _draw_triangles(shapes: Control) -> void:
	for index in _triangle_count:
		shapes.draw_set_transform_matrix(_triangle_xforms[index])
		shapes.draw_rect(TRIANGLE_RECT, _triangle_colors[index])
	shapes.draw_set_transform_matrix(Transform2D.IDENTITY)

func _theme_palette() -> Array:
	return [
		ThemeEngine.get_color(ThemeEngine.Colors.AnimBgColor1),
		ThemeEngine.get_color(ThemeEngine.Colors.AnimBgColor2),
		ThemeEngine.get_color(ThemeEngine.Colors.AnimBgColor3),
	]

func _update_appearance() -> void:
	if not is_node_ready():
		return
	var background := ThemeEngine.get_color(ThemeEngine.Colors.Background)
	_palette = _theme_palette()
	for rect in _colors:
		rect.color = Color.WHITE
		Paint.tint(rect, Themes.paint_value(rect.get_meta("paint"), background) if rect.has_meta("paint") else ThemeEngine.get_paint(ThemeEngine.Colors.Background))
	for rect in _tints:
		Paint.tint(rect, ThemeEngine.get_paint(ThemeEngine.Colors.BackgroundTint).mapped(func(color: Color): return Color(color, 1.0)))
	for material in _blob_mats:
		for index in 3:
			material.set_shader_parameter("color_%d" % (index + 1), _palette[index])
	for dots in _dot_mats:
		dots.set_shader_parameter("opacity", DARK_DOTS_OPACITY if ThemeEngine.dark_mode else float(DOT_DEFAULTS["opacity"]))
	for entry in _media_layers:
		var dim := clampf(float(entry["layer"].get("dim", 0.0)), 0.0, 1.0)
		entry["dim"].color = Color.WHITE
		Paint.tint(entry["dim"], ThemeEngine.get_paint(ThemeEngine.Colors.Background).mapped(func(color: Color): return Color(color, color.a * dim)))
		entry["node"].modulate.a = clampf(float(entry["layer"].get("opacity", 1.0)), 0.0, 1.0)
	for entry in _shader_layers:
		for uniform: String in entry["uniforms"]:
			if not _drives_clock(entry, uniform):
				entry["material"].set_shader_parameter(uniform, Themes.uniform_value(entry["uniforms"][uniform]))
	_redraw()
