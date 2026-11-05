class_name NariSkin extends Node

const MAIN := "main.lua"
const CACHE := "user://cache/nari_skins"
const IMAGES: Array[String] = ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga"]
const TRANS: Array[String] = ["linear", "sine", "quint", "quart", "quad", "expo", "elastic", "cubic", "circ", "bounce", "back", "spring"]
const EASE: Array[String] = ["in", "out", "in_out", "out_in"]
const GEOMETRY: Array[String] = ["x", "y", "width", "height", "shader"]
const SKIPPED: Array[String] = ["type", "children", "image", "hover", "pressed", "disabled", "track", "fill", "thumb", "region", "frames", "fps", "kind", "visual", "command", "sound", "on_click", "on_change", "on_release", "script"]

var folder := ""
var levels := PackedFloat32Array()
var _player: WmpPlayer
var _plugin: NariPlugin
var _windows: Array[Dictionary] = []
var _views: Array[SkinContent] = []
var _commands: Array = []
var _deck := {}
var _mark := 0
var _library: Array = []
var _prefs := {}
var _prefs_changed := false
var _closed := false
var _sizing := {}
var _textures := {}
var _shaders := {}
var _fonts := {}
var _outlines := {}

static func is_skin(source: String) -> bool:
	return not source.is_empty() and (source.get_extension().to_lower() == "nsk" or FileAccess.file_exists(source.path_join(MAIN)))

func open(source: String) -> bool:
	source = WinampSkin.local(source)
	folder = source if DirAccess.dir_exists_absolute(source) else _unpack(source)
	return not folder.is_empty() and FileAccess.file_exists(folder.path_join(MAIN))

func _unpack(source: String) -> String:
	var zip := ZIPReader.new()
	if zip.open(source) != OK:
		return ""
	var main := ""
	for file in zip.get_files():
		if file.get_file() == MAIN and (main.is_empty() or file.length() < main.length()):
			main = file
	var root := main.get_base_dir()
	var target := CACHE.path_join(source.get_file().get_basename())
	for file in zip.get_files():
		var relative := file.trim_prefix(root + "/") if not root.is_empty() else file
		if not main.is_empty() and file.begins_with(root) and not file.ends_with("/") and not ".." in relative:
			DirAccess.make_dir_recursive_absolute(target.path_join(relative).get_base_dir())
			FileAccess.open(target.path_join(relative), FileAccess.WRITE).store_buffer(zip.read_file(file))
	zip.close()
	return target if not main.is_empty() else ""

func set_metrics(_regular: PackedFloat32Array, _bold: PackedFloat32Array, _mono: PackedFloat32Array) -> void:
	pass

func start(name: String, deck: Dictionary, preferences: Dictionary) -> bool:
	_deck = deck
	_prefs = preferences.duplicate()
	_plugin = NariPlugin.new()
	_plugin.id = "skin:" + name
	_plugin.manifest = {"id": _plugin.id, "name": name.get_basename(), "path": folder, "skin": name}
	add_child(_plugin)
	if not _plugin.start(MAIN).is_empty():
		return false
	_plugin.emit_event("skin", [self])
	return true

func shut_down() -> void:
	if _plugin:
		_plugin.teardown()
	for window in _windows:
		if is_instance_valid(window["root"]):
			window["root"].queue_free()
	if _player.is_inside_tree():
		_player.get_tree().root.set_deferred("oversampling_override", 0.0)
	queue_free()

func tick(deck: Dictionary) -> Array:
	_deck = deck
	var copy := deck.duplicate()
	copy.erase("position_s")
	if hash(copy) != _mark:
		_mark = hash(copy)
		_emit("deck", [deck])
	if not _sizing.is_empty():
		var grown: Vector2i = _sizing["size"] + Vector2i((Vector2(DisplayServer.mouse_get_position() - _sizing["from"]) / _player.zoom).round())
		_resize_window(_sizing["window"], grown.max(_sizing["minimum"]))
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_sizing = {}
	var commands := _commands
	_commands = []
	return commands

func views() -> Array:
	var listed: Array = []
	for key in _windows.size():
		if _windows[key]["shown"]:
			listed.append({"key": key, "size": _windows[key]["size"], "resizing": false, "primary": key == 0})
	return listed

func closed() -> bool:
	return _closed

func paint(_key: int) -> Array:
	return []

func needs_paint(key: int) -> bool:
	var reshape: bool = _windows[key]["reshape"]
	_windows[key]["reshape"] = false
	return reshape

func shape(key: int) -> PackedVector2Array:
	var points: PackedVector2Array = _windows[key]["shape"].duplicate()
	for area: Array in _windows[key]["solid"] if not points.is_empty() else []:
		var box := Rect2(area[0], area[1], area[2], area[3])
		points.append_array(PackedVector2Array([box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y), box.position, Vector2.ZERO]))
	return points

func set_solid(id: String, areas: Array) -> void:
	var window := _find(id)
	window["solid"] = areas
	window["reshape"] = true

func hover(_key: int) -> Array:
	return ["", ""]

func window_ready(_key: int) -> void:
	pass

func errors() -> Array:
	return []

func set_library(songs: Array) -> void:
	_library = songs

func file(name: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(folder.path_join(name)) if not ".." in name else PackedByteArray()

func preferences() -> Dictionary:
	var changed := _prefs if _prefs_changed else {}
	_prefs_changed = false
	return changed

func window_commands(key: int) -> Array:
	var commands: Array = _windows[key]["commands"]
	_windows[key]["commands"] = []
	return commands

func input(key: int, kind: String, x: float, y: float, value: int, _shift: bool, _ctrl: bool, _alt: bool) -> void:
	var window := _windows[key]
	match kind:
		"press":
			if value == 0 and window["draggable"]:
				window["commands"].append(["drag"])
		"wheel":
			_emit("wheel", [x, window["id"]])
		"key_down", "key_up":
			_emit("key", [value, kind == "key_down"])

func offset(key: int) -> Vector2:
	return _windows[key]["offset"]

func mount(key: int, pane: Control) -> void:
	var window := _windows[key]
	var root: Control = window["root"]
	if root.get_parent() != pane:
		root.reparent(pane, false)
	root.visible = true
	root.size = window["size"]
	pane.get_viewport().oversampling_override = float(_player.zoom)
	root.scale = Vector2.ONE * pane.size.x / maxf(window["size"].x, 1.0)

func shelve() -> void:
	for window in _windows:
		if not window["shown"] and window["root"].get_parent() != _player._layer:
			window["root"].visible = false
			window["root"].reparent(_player._layer, false)

func show_effects(effect: String, visual: int) -> void:
	_views.assign(_views.filter(is_instance_valid))
	for view in _views:
		var kind: String = view.get_meta("kind")
		var wanted := [effect if kind == "effects" else kind, visual if kind == "effects" else int(view.get_meta("visual")), view.size, view.is_visible_in_tree()]
		if view.get_meta("shown", []) != wanted:
			view.set_meta("shown", wanted)
			view.show_view(wanted[0], wanted[1], wanted[3])

func _emit(event: String, args: Array) -> void:
	if _plugin:
		_plugin.emit_event(event, args)

func _find(id: String) -> Dictionary:
	for window in _windows:
		if window["id"] == id:
			return window
	return _windows[0]

func window(spec: Dictionary) -> Control:
	var root := Control.new()
	var size := Vector2i(int(spec.get("width", 300)), int(spec.get("height", 200)))
	var mask := _image(str(spec.get("mask", "")))
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	root.theme = SkinMenu.tip_theme()
	_player._layer.add_child(root)
	_windows.append({
		"id": str(spec.get("id", _windows.size())),
		"root": root,
		"size": size,
		"shown": bool(spec.get("visible", true)) or _windows.is_empty(),
		"draggable": bool(spec.get("draggable", true)),
		"offset": Vector2(float(spec.get("x", _windows[0]["size"].x if _windows else 0)), float(spec.get("y", 0))),
		"mask": mask,
		"shape": _outline(mask, size) if mask else PackedVector2Array(),
		"solid": [],
		"reshape": false,
		"commands": [],
	})
	_build(root, spec.get("children", []))
	return root

func show_window(id: String, visible := true) -> void:
	var window := _find(id)
	window["shown"] = visible or window == _windows[0]

func is_shown(id: String) -> bool:
	return _find(id)["shown"]

func set_window_size(id: String, width: int, height: int) -> void:
	_resize_window(_find(id), Vector2i(width, height))

func _resize_window(window: Dictionary, size: Vector2i) -> void:
	if size == window["size"]:
		return
	window["size"] = size
	window["shape"] = _outline(window["mask"], size) if window["mask"] else PackedVector2Array()
	window["reshape"] = true
	_emit.call_deferred("resized", [window["id"], size.x, size.y])

func drag(id: String) -> void:
	_find(id)["commands"].append(["drag"])

func resize(id: String, min_width := 100, min_height := 80) -> void:
	_sizing = {"window": _find(id), "from": DisplayServer.mouse_get_position(), "size": _find(id)["size"], "minimum": Vector2i(min_width, min_height)}

func minimize() -> void:
	_windows[0]["commands"].append(["minimize"])

func close() -> void:
	_closed = true

func menu() -> void:
	SkinMenu.popup(_windows[0]["root"].get_parent(), _player._menu(), SkinMenu.nari_colors(), null, _player.zoom * 2)

func command(name: String, value: Variant = null) -> void:
	_commands.append([name, value])

func sound(name: String) -> void:
	if name.begins_with("ui:"):
		Sfx.play(name.trim_prefix("ui:"))
	else:
		command("sound", name)

func color(name: String) -> Color:
	var parts := name.split("@")
	var found := ThemeEngine.get_color(ThemeEngine.Colors[parts[0]]) if ThemeEngine.Colors.has(parts[0]) else Color(parts[0])
	return Color(found, found.a * float(parts[1])) if parts.size() > 1 else found

func deck() -> Dictionary:
	return _deck

func library() -> Array:
	return _library

func pref(key: String, fallback: Variant = null) -> Variant:
	return _prefs.get(key, fallback)

func set_pref(key: String, value: Variant) -> void:
	_prefs[key] = value
	_prefs_changed = true

func texture(name: String) -> Texture2D:
	if not _textures.has(name):
		var image := _image(name)
		_textures[name] = ImageTexture.create_from_image(image) if image else null
	return _textures[name]

func _image(name: String) -> Image:
	var path := folder.path_join(name)
	if not name.get_extension().to_lower() in IMAGES or ".." in name or not FileAccess.file_exists(path):
		return null
	if name.get_extension().to_lower() != "svg":
		return Image.load_from_file(path)
	var image := Image.new()
	image.load_svg_from_buffer(FileAccess.get_file_as_bytes(path), 4.0)
	return image

func _font(name: String) -> Font:
	if not _fonts.has(name):
		var font: Font = FontFile.new() if FileAccess.file_exists(folder.path_join(name)) and not ".." in name else SystemFont.new()
		if font is FontFile:
			font.data = FileAccess.get_file_as_bytes(folder.path_join(name))
		else:
			font.font_names = PackedStringArray([name])
		_fonts[name] = font
	return _fonts[name]

func _material(name: String) -> ShaderMaterial:
	if not _shaders.has(name):
		_shaders[name] = Shader.new()
		_shaders[name].code = FileAccess.get_file_as_string(folder.path_join(name)) if not ".." in name else ""
	var material := ShaderMaterial.new()
	material.shader = _shaders[name]
	return material

func _outline(image: Image, size: Vector2i) -> PackedVector2Array:
	if not _outlines.has(image):
		_outlines[image] = _solid_boxes(image)
	var scale := Vector2(size) / Vector2(image.get_size())
	var points := PackedVector2Array([Vector2.ZERO])
	for box: Rect2 in _outlines[image]:
		points.append_array(Transform2D.IDENTITY.scaled(scale) * PackedVector2Array([box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y), box.position, Vector2.ZERO]))
	return points

func _solid_boxes(image: Image) -> Array[Rect2]:
	var boxes: Array[Rect2] = []
	var open := {}
	for y in image.get_height() + 1:
		var runs := {}
		var start := -1
		for x in image.get_width() + 1:
			var solid := y < image.get_height() and x < image.get_width() and image.get_pixel(x, y).a > 0.5
			if solid and start < 0:
				start = x
			elif not solid and start >= 0:
				runs[Vector2i(start, x)] = open.get(Vector2i(start, x), y)
				start = -1
		for run: Vector2i in open:
			if not runs.has(run):
				boxes.append(Rect2(run.x, open[run], run.y - run.x, y - open[run]))
		open = runs
	return boxes

func _build(parent: Node, specs: Array) -> void:
	for spec: Dictionary in specs:
		add(parent, spec)

func add(parent: Node, spec: Dictionary) -> Control:
	var node := _make(spec)
	parent.add_child(node)
	for key: String in GEOMETRY:
		if spec.has(key):
			_apply(node, key, spec[key])
	for key: String in spec:
		if not key in GEOMETRY and not key in SKIPPED:
			_apply(node, key, spec[key])
	_build(node, spec.get("children", []))
	return node

func _make(spec: Dictionary) -> Control:
	match str(spec.get("type", "group")):
		"image":
			var image := TextureRect.new()
			_picture(image, spec)
			image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			image.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return image
		"button":
			var button := Press.new()
			button.texture_normal = texture(str(spec.get("image", "")))
			button.texture_hover = texture(str(spec.get("hover", "")))
			button.texture_pressed = texture(str(spec.get("pressed", "")))
			button.texture_disabled = texture(str(spec.get("disabled", "")))
			button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
			button.pressed.connect(_click.bind(spec))
			return button
		"text":
			var label: Label = Label.new() if spec.has("font") else NariLabel.new()
			label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			label.clip_text = true
			return label
		"panel":
			var panel := Panel.new()
			var box := StyleBoxFlat.new()
			box.bg_color = color(str(spec.get("color", "PanelBg")))
			box.border_color = color(str(spec.get("border_color", "PanelFg")))
			box.set_border_width_all(int(spec.get("border_width", 0)))
			box.set_corner_radius_all(int(spec.get("radius", 0)))
			box.shadow_size = int(spec.get("shadow", 0))
			box.shadow_color = color(str(spec.get("shadow_color", "#00000059")))
			box.anti_aliasing_size = 0.5
			panel.add_theme_stylebox_override("panel", box)
			panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return panel
		"rect":
			var rect := ColorRect.new()
			rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			return rect
		"slider":
			var slider := Track.new()
			slider.track.texture = texture(str(spec.get("track", "")))
			slider.fill.get_child(0).texture = texture(str(spec.get("fill", "")))
			slider.thumb.texture = texture(str(spec.get("thumb", "")))
			for signal_name in ["on_change", "on_release"]:
				if spec.get(signal_name) is Callable:
					slider.connect("changed" if signal_name == "on_change" else "released", spec[signal_name])
			return slider
		"progress", "thin":
			var bar: Range = ProgressSlider.new() if spec["type"] == "progress" else ThinSlider.new()
			bar.set("editable", true)
			bar.focus_mode = Control.FOCUS_NONE
			if spec.get("on_change") is Callable:
				bar.value_changed.connect(spec["on_change"])
			if spec.get("on_release") is Callable:
				bar.connect("drag_ended" if bar is ProgressSlider else "released", func(_changed := false): spec["on_release"].call(bar.value))
			return bar
		"view":
			var view := SkinContent.new(false)
			view.set_meta("kind", str(spec.get("kind", "effects")))
			view.set_meta("visual", int(spec.get("visual", 0)))
			_views.append(view)
			return view
		"bars":
			return Bars.new(self)
	var group := Control.new()
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return group

func _picture(node: TextureRect, spec: Dictionary) -> void:
	var base := _image(str(spec.get("image", "")))
	var frames := int(spec.get("frames", 1))
	node.texture = texture(str(spec.get("image", "")))
	if not base or frames <= 1 and not spec.has("region"):
		return
	var area: Array = spec.get("region", [0, 0, base.get_width() / frames, base.get_height()])
	var shots: Array = range(frames).map(func(frame: int): return ImageTexture.create_from_image(base.get_region(Rect2i(area[0] + frame * area[2], area[1], area[2], area[3]))))
	node.texture = shots[0]
	if frames > 1:
		create_tween().bind_node(node).set_loops().tween_method(func(frame: float): node.texture = shots[mini(int(frame), frames - 1)], 0.0, float(frames), frames / float(spec.get("fps", 12)))

func _click(spec: Dictionary) -> void:
	if spec.has("sound"):
		sound(str(spec["sound"]))
	if spec.has("command"):
		command(str(spec["command"]), spec.get("value"))
	if spec.get("on_click") is Callable:
		spec["on_click"].call()

func _apply(node: Control, key: String, value: Variant) -> void:
	match key:
		"x":
			node.position.x = value
		"y":
			node.position.y = value
		"width":
			node.size.x = value
		"height":
			node.size.y = value
		"shader":
			node.material = _material(str(value))
		"uniforms":
			for name: String in value:
				uniform(node, name, value[name])
		"font":
			node.add_theme_font_override("font", _font(str(value)))
		"font_size" when not node is NariLabel:
			node.add_theme_font_size_override("font_size", int(value))
		"align":
			node.set("horizontal_alignment", ["left", "center", "right"].find(value))
		"pivot":
			node.pivot_offset = node.size * 0.5 if str(value) == "center" else _value(node, "pivot_offset", value)
		"tooltip":
			node.tooltip_text = str(value)
		"alpha":
			node.modulate.a = value
		"color" when node is NariLabel or node is ThinSlider:
			node.set("use_custom_color", not ThemeEngine.Colors.has(str(value)))
			node.set("color" if ThemeEngine.Colors.has(str(value)) else "custom_color", ThemeEngine.Colors.get(str(value), color(str(value))))
		"color" when node is Label:
			node.add_theme_color_override("font_color", color(str(value)))
		_:
			if key in node:
				node.set(key, _value(node, key, value))

func _value(node: Object, key: String, value: Variant) -> Variant:
	var current: Variant = node.get_indexed(key)
	if value is String and value.get_extension().to_lower() in IMAGES and (current == null or current is Texture2D):
		return texture(value)
	if current is Color and value is String:
		return color(value)
	if current is Vector2 and value is Array:
		return Vector2(value[0], value[1])
	if current is Vector2 and (value is float or value is int):
		return Vector2.ONE * value
	return value

func uniform(node: CanvasItem, name: String, value: Variant) -> void:
	if not node.material is ShaderMaterial:
		return
	if value is String:
		value = texture(value) if value.get_extension().to_lower() in IMAGES else color(value)
	elif value is Array:
		value = Vector2(value[0], value[1]) if value.size() == 2 else Vector3(value[0], value[1], value[2]) if value.size() == 3 else Vector4(value[0], value[1], value[2], value[3])
	node.material.set_shader_parameter(name, value)

func animate(node: Node, properties: Dictionary, time := 0.3, options := {}) -> Tween:
	var tween := create_tween().bind_node(node).set_parallel()
	tween.set_trans(maxi(TRANS.find(str(options.get("trans", "sine"))), 0) as Tween.TransitionType)
	tween.set_ease(maxi(EASE.find(str(options.get("ease", "in_out"))), 0) as Tween.EaseType)
	if options.has("loops"):
		tween.set_loops(int(options["loops"]))
	var back := {}
	for passes in (2 if options.get("yoyo", false) else 1):
		for key: String in properties:
			var paths: Dictionary = properties[key] if key == "uniforms" else {key: properties[key]}
			for path: String in paths:
				var target := "material:shader_parameter/" + path if key == "uniforms" else path
				if key == "uniforms" and node.get_indexed(target) == null:
					node.material.set_shader_parameter(path, RenderingServer.shader_get_parameter_default(node.material.shader.get_rid(), path))
				back[target] = back.get(target, node.get_indexed(target))
				var tweener := tween.tween_property(node, target, _value(node, target, paths[path]) if passes == 0 else back[target], time)
				if passes == 0 and options.has("delay"):
					tweener.set_delay(float(options["delay"]))
		if passes == 0 and options.get("yoyo", false):
			tween.chain()
	return tween

class Press extends BaseButton:
	var texture_normal: Texture2D:
		set(value):
			texture_normal = value
			queue_redraw()
	var texture_hover: Texture2D:
		set(value):
			texture_hover = value
			queue_redraw()
	var texture_pressed: Texture2D:
		set(value):
			texture_pressed = value
			queue_redraw()
	var texture_disabled: Texture2D:
		set(value):
			texture_disabled = value
			queue_redraw()

	func _draw() -> void:
		var picked: Texture2D = [texture_normal, texture_pressed, texture_hover, texture_disabled, texture_pressed][get_draw_mode()]
		if picked or texture_normal:
			draw_texture_rect(picked if picked else texture_normal, Rect2(Vector2.ZERO, size), false)

	func _make_custom_tooltip(text: String) -> Object:
		var unit := get_global_transform_with_canvas().get_scale().x
		var tip: NariPanelContainer = SkinMenu.tooltip(text, self)
		tip.corner_radius = 8.0 * unit
		tip.padding = roundi(6.0 * unit)
		tip.get_child(0).font_size = roundi(13.0 * unit)
		return tip

class Bars extends Control:
	var skin: NariSkin
	var color := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg)
	var gap := 0.2

	func _init(owner: NariSkin) -> void:
		skin = owner
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _process(_delta: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var slot := size.x / maxf(skin.levels.size(), 1.0)
		for bar in skin.levels.size():
			var height := maxf(skin.levels[bar] * size.y, 1.0)
			draw_rect(Rect2(slot * (bar + gap * 0.5), size.y - height, slot * (1.0 - gap), height), color)

class Track extends Control:
	signal changed(value: float)
	signal released(value: float)

	var vertical := false
	var held := false
	var step := 0.05
	var track := TextureRect.new()
	var fill := Control.new()
	var thumb := TextureRect.new()
	var value := 0.0:
		set(next):
			value = clampf(next, 0.0, 1.0)
			_layout()
	var knob := 0.0:
		set(next):
			knob = next
			_layout()

	func _init() -> void:
		var inside := TextureRect.new()
		for part: TextureRect in [track, inside, thumb]:
			part.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			part.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.clip_contents = true
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		fill.add_child(inside)
		for part: Control in [track, fill, thumb]:
			add_child(part)
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		resized.connect(_layout)

	func _layout() -> void:
		if fill.get_child_count() == 0:
			return
		thumb.size = Vector2.ONE * knob if knob > 0.0 else thumb.texture.get_size() if thumb.texture else Vector2.ZERO
		var room := size - thumb.size
		track.size = size
		thumb.position = Vector2(room.x * 0.5, room.y * (1.0 - value)) if vertical else Vector2(room.x * value, room.y * 0.5)
		fill.size = Vector2(size.x, size.y * value) if vertical else Vector2(size.x * value, size.y)
		fill.position = Vector2(0.0, size.y - fill.size.y)
		fill.get_child(0).position = -fill.position
		fill.get_child(0).size = size

	func _gui_input(event: InputEvent) -> void:
		var button := event as InputEventMouseButton
		if button and button.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN] and button.pressed:
			value += step if button.button_index == MOUSE_BUTTON_WHEEL_UP else -step
			changed.emit(value)
			released.emit(value)
		elif button and button.button_index == MOUSE_BUTTON_LEFT:
			held = button.pressed
		if held and event is InputEventMouse:
			value = 1.0 - event.position.y / size.y if vertical else event.position.x / size.x
			changed.emit(value)
		if button and button.button_index == MOUSE_BUTTON_LEFT and not held:
			released.emit(value)
		accept_event()
