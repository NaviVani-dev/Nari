class_name Visualizers extends Control

signal shade_changed(tone: String)

const COUNT := 5
const SCOPE := 1
const BANDS := 32
const WAVE := 128
const LATENCY_MS := 180
const ATTACK := 0.5
const RELEASE := 0.14
const PEAK_FALL := 0.75
const FADE_TIME := 0.25
const PICKER_LIMIT := 10
const NAMES := ["Blocks", "Scope", "Ring", "Tunnel", "Mesh"]
const MORE_ICON := preload("res://assets/icons/chevron_right.svg")
const STAGE := "VisualizerStage"
const LIFTED := &"contrast_original"
const SHADE_INTERVAL := 1.0
const BACKDROP_LIMIT := 0.3

static var extra: Array[Dictionary] = []
static var last_mode := 0

var source: Callable = _music_spectrum
var tone := ""
var backdrop := true:
	set(value):
		backdrop = value
		if is_node_ready():
			_paint()
			_sync_cover()

var mode := -1:
	set(value):
		var next := clampi(value, -1, count() - 1)
		if next == mode:
			return
		mode = next
		if mode >= 0:
			last_mode = mode
		if is_node_ready():
			_swap()

@onready var _surfaces: Array[ColorRect] = [%Blocks, %Scope, %Ring, %Tunnel, %Mesh, %Custom]
@onready var _custom: ColorRect = %Custom
@onready var _canvas: Control = %Canvas

var _stage: Control
var _background: Control
var _bands := PackedVector4Array()
var _peaks := PackedVector4Array()
var _wave := PackedVector4Array()
var _samples := PackedFloat32Array()
var _levels := PackedFloat32Array()
var _held := PackedFloat32Array()
var _level := 0.0
var _bass := 0.0
var _travel := 0.0
var _fade: Tween
var _shade_elapsed := 0.0

static func count() -> int:
	return COUNT + extra.size()

static func register(entry: Dictionary) -> void:
	extra.append(entry)

static func unregister(entry: Dictionary) -> void:
	extra.erase(entry)

static func choices() -> Array:
	var list: Array = [{"title": "Off", "mode": -1}]
	for index in COUNT:
		list.append({"title": NAMES[index], "mode": index})
	for index in extra.size():
		var entry := extra[index]
		var menu: Callable = entry.get("menu", Callable())
		var items: Variant = menu.call() if menu.is_valid() else null
		list.append({"title": str(entry.get("name", "Visualizer %d" % (COUNT + index + 1))), "mode": COUNT + index, "items": items if items is Array else []})
	return list

static func total() -> int:
	var amount := COUNT
	for entry in extra:
		var menu: Callable = entry.get("menu", Callable())
		var items: Variant = menu.call() if menu.is_valid() else null
		amount += _leaves(items) if items is Array and not (items as Array).is_empty() else 1
	return amount

static func _leaves(items: Array) -> int:
	var amount := 0
	for item: Variant in items:
		var children: Variant = item.get("items") if item is Dictionary else null
		amount += _leaves(children) if children is Array and not (children as Array).is_empty() else 1
	return amount

static func lift_contrast(root: Node, wanted: String) -> void:
	if root == null or not is_instance_valid(root):
		return
	var nodes: Array[Node] = root.find_children("*", "", true, false)
	for node in nodes:
		if is_instance_valid(node) and node.has_meta(LIFTED):
			_restore(node)
	if wanted.is_empty():
		return
	for node in nodes:
		if not is_instance_valid(node) or not node.is_inside_tree() or _shielded(node, root):
			continue
		if node is NariButton:
			_lift_button(node, wanted)
		elif (node is NariLabel or node is Icon) and not _inside_button(node, root):
			_lift_plain(node, wanted)

static func _inside_button(node: Node, root: Node) -> bool:
	var parent := node.get_parent()
	while parent and parent != root:
		if parent is NariButton:
			return true
		parent = parent.get_parent()
	return false

static func _shielded(node: Node, root: Node) -> bool:
	var parent := node.get_parent()
	while parent:
		if _backdrop(parent) > BACKDROP_LIMIT:
			return true
		if parent == root:
			return false
		parent = parent.get_parent()
	return false

static func _backdrop(node: Node) -> float:
	if not node is PanelContainer and not node is Panel:
		return 0.0
	var alpha := (node as CanvasItem).self_modulate.a
	if node is NariButton:
		if node._accented():
			return alpha
		if node.flat:
			return 0.0
		if node is HintChip and not node.solid:
			return ThemeEngine.get_color(node.fg_color).a * HintChip.FILL_ALPHA * alpha
	if node is NariPanelContainer:
		if node._textured:
			return alpha
		return node._fill_paint().color.a * alpha
	var box: StyleBox = (node as Control).get_theme_stylebox("panel")
	if box is StyleBoxFlat:
		return (box as StyleBoxFlat).bg_color.a * alpha
	if box is StyleBoxTexture:
		return alpha
	return 0.0

static func _needs_lift(color: Color, wanted: String) -> bool:
	if color.a <= 0.05:
		return false
	return color.get_luminance() < 0.5 if wanted == "dark" else color.get_luminance() > 0.5

static func _contrasted(color: Color, wanted: String) -> Color:
	if wanted == "dark":
		return Color.from_hsv(color.h, color.s * 0.12, 0.98, color.a)
	return Color.from_hsv(color.h, color.s * 0.25, 0.1, color.a)

static func _lift_plain(node: Node, wanted: String) -> void:
	var current := ThemeEngine.resolve(node.use_custom_color, node.custom_color, node.color)
	if not _needs_lift(current, wanted):
		return
	node.set_meta(LIFTED, [node.use_custom_color, node.custom_color])
	node.custom_color = _contrasted(current, wanted)
	node.use_custom_color = true

static func _lift_button(button: NariButton, wanted: String) -> void:
	if _backdrop(button) > BACKDROP_LIMIT:
		return
	var fill := button._fill_paint()
	var current := button._foreground_paint().color
	if not _needs_lift(current, wanted):
		return
	button.set_meta(LIFTED, [button.use_custom_colors, button.custom_fg_color, button.custom_fg_paint, button.custom_bg_paint, button.custom_gradient_paint])
	button.custom_bg_paint = fill
	button.custom_gradient_paint = button._glow_paint()
	button.custom_fg_color = _contrasted(current, wanted)
	button.custom_fg_paint = Paint.solid(_contrasted(current, wanted))
	button.use_custom_colors = true

static func _restore(node: Node) -> void:
	var saved: Array = node.get_meta(LIFTED)
	node.remove_meta(LIFTED)
	if node is NariButton:
		node.custom_fg_color = saved[1]
		node.custom_fg_paint = saved[2]
		node.custom_bg_paint = saved[3]
		node.custom_gradient_paint = saved[4]
		node.use_custom_colors = saved[0]
	else:
		node.custom_color = saved[1]
		node.use_custom_color = saved[0]

static func press(current: int, show: Callable) -> void:
	if total() <= PICKER_LIMIT:
		show.call(current + 1 if current + 1 < count() else -1)
	elif current < 0:
		show.call(clampi(last_mode, 0, count() - 1))
	else:
		open_menu("Visualizers", choices(), current, show, -1)

static func open_menu(title: String, options: Array, current: int, show: Callable, owner_mode: int) -> void:
	var dialog := Dialog.menu(title)
	var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
	list.separation = 0
	list.follow_focus = true
	dialog.content.add_child(list)
	dialog.popup()
	var focused := 0
	for index in options.size():
		var option: Dictionary = options[index]
		if int(option.get("mode", owner_mode)) == current and owner_mode < 0 or bool(option.get("chosen", false)):
			focused = index
	list.set_items(options, func(option: Dictionary) -> NariButton:
		var label := str(option.get("title", ""))
		var target := int(option.get("mode", owner_mode))
		var items: Variant = option.get("items")
		if items is Array and not (items as Array).is_empty():
			var more := dialog.make_option(label, open_menu.bind(label, items, current, show, target))
			more.icon = MORE_ICON
			more.icon_right = true
			more.icon_size = Vector2.ONE * 56
			more.padding_right = 40
			return more
		var chosen := bool(option.get("chosen", false)) if owner_mode >= 0 else target == current
		return dialog.make_choice(label, chosen, func():
			var action: Variant = option.get("action")
			if action is Callable and (action as Callable).is_valid():
				(action as Callable).call()
			show.call(target)))
	list.custom_minimum_size.y = list.container.cell_height * minf(options.size(), ItemMenu.VISIBLE_OPTIONS)
	list.focus_item(focused)

func _ready() -> void:
	_bands.resize(ceili(BANDS / 4.0))
	_peaks.resize(ceili(BANDS / 4.0))
	_wave.resize(ceili(WAVE / 4.0))
	_samples.resize(WAVE)
	_levels.resize(BANDS)
	_held.resize(BANDS)
	_adopt_stage()
	for surface in _surfaces:
		surface.visible = false
	_stage.modulate.a = 0.0
	set_process(false)
	MediaPlayer.set_spectrum_latency(LATENCY_MS)
	MediaPlayer.current_song_changed.connect(_load_cover.unbind(1))
	ThemeEngine.follow(self, _paint)
	_stage.resized.connect(_resize)
	_paint()
	_resize()
	if mode >= 0:
		_swap()

func _adopt_stage() -> void:
	_stage = self
	var background: Control = null
	var ancestor := get_parent()
	while ancestor and background == null:
		var candidate := ancestor.get_node_or_null("BG") as Control
		if candidate and candidate.has_method("host"):
			background = candidate
		ancestor = ancestor.get_parent()
	if background == null:
		return
	_background = background
	_stage = Control.new()
	_stage.name = STAGE
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in get_children():
		remove_child(child)
		_stage.add_child(child)
	background.host(_stage)
	_sync_stage()

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED:
		_sync_stage()

func _exit_tree() -> void:
	for header in headers():
		lift_contrast(header, "")
	if _background and is_instance_valid(_background):
		_background.cover(self, false)
	if _stage and _stage != self and is_instance_valid(_stage):
		_stage.queue_free()

func _sync_stage() -> void:
	if _stage == null or _stage == self or not is_instance_valid(_stage):
		return
	_stage.visible = is_visible_in_tree()
	_sync_cover()

func _update_shade() -> void:
	var plugin := _plugin()
	var next := ""
	if mode >= 0 and mode < COUNT and backdrop:
		next = "light" if ThemeEngine.get_color(ThemeEngine.Colors.Background).get_luminance() > 0.5 else "dark"
	elif mode >= COUNT and not bool(plugin.get("transparent", true)):
		var shade: Variant = plugin.get("shade", "dark")
		if shade is Callable:
			shade = (shade as Callable).call() if (shade as Callable).is_valid() else "dark"
		next = "light" if str(shade) == "light" else "dark"
	if next != tone:
		tone = next
		shade_changed.emit(tone)

func headers() -> Array[Node]:
	var found: Array[Node] = []
	if _background and is_instance_valid(_background):
		var hints := _background.get_parent().get_node_or_null("AppHints")
		if hints:
			found.append(hints)
	return found

func _sync_cover() -> void:
	if _background == null or not is_instance_valid(_background):
		return
	var opaque := mode >= 0 and mode < COUNT and backdrop or mode >= COUNT and not bool(_plugin().get("transparent", true))
	_background.cover(self, opaque and is_visible_in_tree() and _stage.modulate.a >= 1.0)

func _process(delta: float) -> void:
	var data: PackedByteArray = source.call()
	var live := data.size() >= BANDS + WAVE + 1

	for band in BANDS:
		var target := (float(data[band]) / 255.0) if live else 0.0
		var rate: float = ATTACK if target > _levels[band] else RELEASE
		_levels[band] = lerpf(_levels[band], target, clampf(rate * delta * 60.0, 0.0, 1.0))
		_held[band] = maxf(_levels[band], _held[band] - PEAK_FALL * delta)

	for slot in _bands.size():
		var first := slot * 4
		_bands[slot] = Vector4(_levels[first], _levels[first + 1], _levels[first + 2], _levels[first + 3])
		_peaks[slot] = Vector4(_held[first], _held[first + 1], _held[first + 2], _held[first + 3])

	for index in WAVE:
		_samples[index] = (float(data[BANDS + index]) - 128.0) / 127.0 if live else 0.0
	for slot in _wave.size():
		var first := slot * 4
		_wave[slot] = Vector4(_samples[first], _samples[first + 1], _samples[first + 2], _samples[first + 3])

	var loudness := (float(data[BANDS + WAVE]) / 255.0) if live else 0.0
	_level = lerpf(_level, loudness, clampf(RELEASE * 2.0 * delta * 60.0, 0.0, 1.0))
	_shade_elapsed += delta
	if _shade_elapsed >= SHADE_INTERVAL:
		_shade_elapsed = 0.0
		_update_shade()
	_bass = (_levels[0] + _levels[1] + _levels[2] + _levels[3]) * 0.25
	_travel += delta * (0.45 + _bass * 2.4)
	_push()

func _music_spectrum() -> PackedByteArray:
	return MediaPlayer.get_spectrum() if MediaPlayer.is_playing() else PackedByteArray()

func _push() -> void:
	if mode < 0:
		return
	var shader: ShaderMaterial = _surfaces[mini(mode, COUNT)].material
	shader.set_shader_parameter("bands", _bands)
	shader.set_shader_parameter("peaks", _peaks)
	shader.set_shader_parameter("wave", _wave)
	shader.set_shader_parameter("level", _level)
	shader.set_shader_parameter("bass", _bass)
	shader.set_shader_parameter("travel", _travel)
	if mode < COUNT:
		return
	var duration := MediaPlayer.get_duration()
	var progress := clampf(float(MediaPlayer.get_position()) / duration, 0.0, 1.0) if duration > 0 else 0.0
	shader.set_shader_parameter("progress", progress)
	var update: Callable = _plugin().get("update", Callable())
	if update.is_valid():
		update.call({"bands": _levels, "peaks": _held, "wave": _samples, "level": _level, "bass": _bass, "travel": _travel, "progress": progress, "size": _stage.size})

func _plugin() -> Dictionary:
	return extra[mode - COUNT] if mode >= COUNT and mode - COUNT < extra.size() else {}

func _clear_canvas() -> void:
	for child in _canvas.get_children():
		child.queue_free()
	_canvas.visible = false

func _load_cover() -> void:
	if mode < COUNT:
		return
	var song := MediaPlayer.get_current_song()
	var texture: Texture2D = null
	if not song.is_empty():
		var cover := MediaPlayer.cover_of(song)
		texture = await MediaPlayer.get_cover_texture(cover[0], cover[1])
	if not is_inside_tree():
		return
	(_custom.material as ShaderMaterial).set_shader_parameter("cover", texture)
	if texture:
		MediaPlayer.watch_cover(texture, _custom)

func _swap() -> void:
	if _fade:
		_fade.kill()
	_fade = create_tween()
	_update_shade()
	if mode < 0:
		_sync_cover()
		_fade.tween_property(_stage, "modulate:a", 0.0, FADE_TIME)
		_fade.tween_callback(func():
			for surface in _surfaces:
				surface.visible = false
			_clear_canvas()
			set_process(false))
		return
	_clear_canvas()
	var plugin := _plugin()
	if not plugin.is_empty():
		var custom: ShaderMaterial = _custom.material
		custom.shader = plugin.get("shader")
		var params: Dictionary = plugin["params"]
		for key: Variant in params:
			custom.set_shader_parameter(str(key), params[key])
		_paint()
		_resize()
		_load_cover()
		var build: Callable = plugin["build"]
		_canvas.visible = build.is_valid()
		if build.is_valid():
			build.call(_canvas)
	for index in _surfaces.size():
		_surfaces[index].visible = index == mini(mode, COUNT) and (mode < COUNT or plugin.get("shader") != null)
	set_process(true)
	_push()
	_sync_cover()
	_fade.tween_property(_stage, "modulate:a", 1.0, FADE_TIME)
	_fade.tween_callback(_sync_cover)

func _paint() -> void:
	var low := ThemeEngine.get_color(ThemeEngine.Colors.AccentGradient)
	var high := ThemeEngine.get_color(ThemeEngine.Colors.BackgroundTint)
	var glow := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg)
	var back := ThemeEngine.get_color(ThemeEngine.Colors.Background)
	var back_2 := ThemeEngine.get_color(ThemeEngine.Colors.BackgroundGradient)
	for surface in _surfaces:
		var shader: ShaderMaterial = surface.material
		shader.set_shader_parameter("color_1", low)
		shader.set_shader_parameter("color_2", high)
		shader.set_shader_parameter("color_3", glow)
		shader.set_shader_parameter("color_back", back)
		shader.set_shader_parameter("color_back_2", back_2)
		shader.set_shader_parameter("backdrop", backdrop)
	_update_shade()

func _resize() -> void:
	for surface in _surfaces:
		var shader: ShaderMaterial = surface.material
		shader.set_shader_parameter("rect_size", _stage.size)
