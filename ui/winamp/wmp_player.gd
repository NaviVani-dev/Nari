class_name WmpPlayer extends Node

signal closed
signal skin_requested(source: String)
signal files_dropped(files: PackedStringArray)

const SECTION := "mini_player"
const PREFERENCES := "wmp_skins"
const LAYER := 120
const GAP := 25.0
const SOUND_SLOT := 1000
const CONTENT_HEIGHT := 600.0
const AUDIO := ["*.mp3, *.flac, *.ogg, *.opus, *.wav, *.m4a, *.aac, *.wma ; Audio files"]
const KEYS := {KEY_ENTER: 13, KEY_KP_ENTER: 13, KEY_ESCAPE: 27, KEY_BACKSPACE: 8, KEY_TAB: 9, KEY_SPACE: 32, KEY_LEFT: 37, KEY_UP: 38, KEY_RIGHT: 39, KEY_DOWN: 40, KEY_DELETE: 46}
const FONTS := {"regular": [["Segoe UI", "Tahoma", "Arial", "Liberation Sans", "DejaVu Sans"], 400], "bold": [["Segoe UI", "Tahoma", "Arial", "Liberation Sans", "DejaVu Sans"], 700], "mono": [["Lucida Console", "Courier New", "Liberation Mono", "DejaVu Sans Mono"], 400]}

static var _active := 0

var zoom := 1
var on_top := true

var _skin: Object
var _name := ""
var _source := ""
var _widths: Array[PackedFloat32Array] = []
var _layer := CanvasLayer.new()
var _panes := {}
var _windows := {}
var _sizes := {}
var _veiled := false
var _textures := {}
var _fonts := {}
var _art: Texture2D
var _levels := PackedFloat32Array()
var _wave := PackedFloat32Array()
var _queue: Array = []
var _queue_version := -1
var _volume := 1.0
var _last: Control
var _started := false
var _sounds := {}
var _shapes := {}
var _log := Log.new("Skins", Color("9b6bff"))
var _effect := "visualizer"
var _visual := 0
var _content := SkinContent.new(false)

func open(source: String) -> bool:
	_source = source
	_name = source.get_file()
	_skin = ClassDB.instantiate("WmpSkin")
	return _skin.open(ProjectSettings.globalize_path(WinampSkin.local(source)))

func _restart() -> void:
	_content.reparent(_layer, false)
	_skin.shut_down()
	for window: Window in _windows.values():
		window.queue_free()
	for key: int in _panes:
		if not _windows.has(key):
			_panes[key].queue_free()
	_windows.clear()
	_panes.clear()
	_shapes.clear()
	_textures.clear()
	_sounds.clear()
	open(_source)
	_skin.set_metrics(_widths[0], _widths[1], _widths[2])
	_started = _skin.start(_name, _deck(), SettingsManager.get_value(PREFERENCES, _name, {}))
	_send_library()

func _ready() -> void:
	zoom = int(SettingsManager.get_value(SECTION, "wmp_zoom", zoom))
	on_top = bool(SettingsManager.get_value(SECTION, "on_top", on_top))
	_levels.resize(20)
	_wave.resize(64)
	var widths := _widths
	for kind: String in FONTS:
		var font := SystemFont.new()
		font.font_names = PackedStringArray(FONTS[kind][0])
		font.font_weight = FONTS[kind][1]
		_fonts[kind] = font
		var table := PackedFloat32Array()
		for code in range(32, 127):
			table.append(font.get_string_size(char(code), HORIZONTAL_ALIGNMENT_LEFT, -1, 100).x / 100.0)
		widths.append(table)
	_skin.set_metrics(widths[0], widths[1], widths[2])
	_layer.layer = LAYER
	get_tree().root.add_child(_layer)
	_veil.call_deferred()
	_active += 1
	if OS.has_feature("pc"):
		get_window().transparent = true
		get_tree().root.transparent_bg = true
	_effect = str(SettingsManager.get_value(SECTION, "wmp_effect", _effect)).replace("spectrum", "visualizer")
	_visual = int(SettingsManager.get_value(SECTION, "wmp_visual", _visual))
	_content.visible = false
	_layer.add_child(_content)
	MediaPlayer.playback_changed.connect(_on_playback)
	Main.tray_changed.connect(func(hidden: bool):
		for window: Window in _windows.values():
			window.visible = not hidden)
	await _on_playback(MediaPlayer.get_playback_state())
	_started = _skin.start(_name, _deck(), SettingsManager.get_value(PREFERENCES, _name, {}))
	MediaPlayer.library_changed.connect(_send_library)
	_send_library()

func _send_library() -> void:
	var tracks: Array = await MediaPlayer.get_tracks()
	if _started:
		_skin.set_library(tracks.map(_song))

func _exit_tree() -> void:
	if _skin:
		_skin.shut_down()
	if _veiled:
		SkinMenu.unveil()
	_active -= 1
	DisplayServer.window_set_mouse_passthrough(PackedVector2Array(), get_window().get_window_id())
	if _active == 0 and OS.has_feature("pc"):
		get_window().transparent = false
		get_tree().root.transparent_bg = false
	_layer.queue_free()

func focus() -> void:
	for pane: Control in _panes.values():
		pane.grab_focus()
		return

func _veil() -> void:
	if is_inside_tree() and not _veiled:
		_veiled = true
		SkinMenu.veil(get_tree())

func _show_content(pane: WmpPane) -> void:
	var found := pane.effects_area()
	if found.is_empty():
		if _content.get_parent() == pane:
			_content.visible = false
		return
	if _content.get_parent() != pane:
		_content.reparent(pane, false)
	var area: Rect2 = found[0]
	var scale := clampf(area.size.y / CONTENT_HEIGHT, 0.1, 1.0)
	_content.position = area.position
	_content.scale = Vector2.ONE * scale
	_content.size = area.size / scale
	var mask: Array[Rect2] = []
	for part: Rect2 in found[2]:
		mask.append(Rect2(part.position / scale, part.size / scale))
	_content.mask = mask
	_content.visible = true
	RenderingServer.canvas_item_set_draw_index(_content.get_canvas_item(), found[1])
	_content.show_view(_effect, _visual)

func _set_effect(effect: String, visual := -1) -> void:
	_effect = effect
	if visual >= 0:
		_visual = visual
	SettingsManager.set_value(SECTION, "wmp_effect", _effect)
	SettingsManager.set_value(SECTION, "wmp_visual", _visual)

func _step_effect(step: int) -> void:
	var options: Array = []
	for index in Visualizers.count():
		options.append(["visualizer", index])
	options.append_array([["lyrics", -1], ["cover", -1]])
	var at := 0
	for index in options.size():
		if options[index][0] == _effect and (_effect != "visualizer" or options[index][1] == _visual):
			at = index
	var next: Array = options[posmod(at + step, options.size())]
	_set_effect(next[0], next[1])

func _on_playback(state: Dictionary) -> void:
	var version := int(state.get("queue_version", 0))
	if version != _queue_version:
		_queue_version = version
		_queue = await MediaPlayer.get_queue()
	var song := MediaPlayer.get_current_song()
	var cover := MediaPlayer.cover_of(song)
	_art = null
	if not song.is_empty():
		_art = await MediaPlayer.get_cover_texture(cover[0], cover[1])

func _song(song: Dictionary) -> Dictionary:
	return {"title": str(song.get("title", "")), "artist": str(song.get("artist", "")), "album": str(song.get("album", "")), "uri": str(song.get("id", "")), "duration_s": float(song.get("duration", 0)) / 1000.0}

func _deck() -> Dictionary:
	var song := MediaPlayer.get_current_song()
	var presets: Array = Equalizer.presets().keys()
	var volume := float(SettingsManager.playback.volume)
	return {
		"state": 3 if MediaPlayer.is_playing() else 2 if not song.is_empty() else 1,
		"song": _song(song) if not song.is_empty() else {},
		"position_s": MediaPlayer.get_position() / 1000.0,
		"bitrate": int(song.get("bitrate", 0)) * 1000,
		"volume": roundi(volume * 100.0),
		"mute": volume <= 0.0,
		"balance": int(SettingsManager.playback.balance),
		"shuffle": MediaPlayer.is_shuffled(),
		"repeat": MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF,
		"queue": _queue.map(_song),
		"playing": int(MediaPlayer.get_playback_state().get("index", -1)),
		"eq_on": SettingsManager.equalizer.enabled,
		"eq_bands": Equalizer.gains(),
		"eq_preamp": float(SettingsManager.equalizer.preamp),
		"eq_presets": presets,
		"eq_preset": presets.find(Equalizer.current_preset()),
	}

func _process(delta: float) -> void:
	if not _started:
		return
	_tick_only()
	if _skin.closed():
		_restart()
		Main.leave_mini()
		return
	var data := MediaPlayer.get_spectrum() if MediaPlayer.is_playing() else PackedByteArray()
	var live := data.size() >= 161
	for bar in _levels.size():
		_levels[bar] = maxf(float(data[bar * 31 / (_levels.size() - 1)]) / 255.0 if live else 0.0, _levels[bar] - delta * 2.0)
	for index in _wave.size():
		_wave[index] = absf(float(data[32 + index * 2]) - 128.0) / 128.0 if live else 0.0
	_sync_views()

func _tick_only() -> void:
	for error in _skin.errors():
		_log.warn(error)
	for command: Array in _skin.tick(_deck()):
		_command(command[0], command[1])
	var preferences: Dictionary = _skin.preferences()
	if not preferences.is_empty():
		SettingsManager.set_value(PREFERENCES, _name, preferences)

func _sync_views() -> void:
	var seen := {}
	for view: Dictionary in _skin.views():
		var key: int = view["key"]
		var size: Vector2i = view["size"]
		seen[key] = true
		_sizes[key] = size
		var window := _window_for(key, view["primary"])
		var wanted := size * zoom
		if view["resizing"]:
			var current := Vector2(window.size) / zoom
			if Vector2i(current.round()) != size:
				_skin.input(key, "resized", roundf(current.x), roundf(current.y), 0, false, false, false)
		elif window.size != wanted:
			if view["primary"]:
				if not is_queued_for_deletion():
					Main.resize_mini(wanted)
			else:
				window.size = wanted
		else:
			_skin.window_ready(key)
		window.always_on_top = on_top
		for command: Array in _skin.window_commands(key):
			_window_command(window, command)
		var pane: WmpPane = _panes[key]
		var unit := pane.size.x / maxf(size.x, 1.0)
		if _skin.needs_paint(key) or not pane.fresh(unit):
			pane.show_ops(_skin.paint(key), unit)
			_shape(key, window, size)
		else:
			pane.animate()
		_show_content(pane)
		var hover: Array = _skin.hover(key)
		pane.tooltip_text = str(hover[0])
		pane.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if str(hover[1]).to_lower() == "hand" else Control.CURSOR_ARROW
	for key: int in _panes.keys():
		if not seen.has(key):
			if _content.get_parent() == _panes[key]:
				_content.reparent(_layer, false)
				_content.visible = false
			if _windows.has(key):
				_windows[key].queue_free()
				_windows.erase(key)
			else:
				_panes[key].queue_free()
			_panes.erase(key)

func _shape(key: int, window: Window, size: Vector2i) -> void:
	var scale := float(window.size.x) / maxf(size.x, 1.0)
	var points := PackedVector2Array()
	for point in _skin.shape(key):
		points.append(point * scale)
	if _shapes.get(key) != points:
		_shapes[key] = points
		DisplayServer.window_set_mouse_passthrough(points, window.get_window_id())

func _sound(name: String) -> void:
	var native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
	if not native:
		return
	if not _sounds.has(name):
		_sounds[name] = SOUND_SLOT + _sounds.size()
		native.loadEffect(_sounds[name], _skin.file(name), name)
	native.playEffect(_sounds[name], SettingsManager.playback.sounds_volume / 100.0)

func _play_list(ids: Array, index: int) -> void:
	var tracks: Array = []
	for id in ids:
		var song: Dictionary = await MediaPlayer.get_song(str(id))
		if not song.is_empty():
			tracks.append(song)
	if not tracks.is_empty():
		MediaPlayer.play_tracks(tracks, str(tracks[clampi(index, 0, tracks.size() - 1)].get("id", "")))

func _window_for(key: int, primary: bool) -> Window:
	if _panes.has(key):
		return _windows[key] if _windows.has(key) else get_window()
	var pane := WmpPane.new(self, key)
	if primary:
		_layer.add_child(pane)
		pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_panes[key] = pane
		return get_window()
	var window := Window.new()
	window.visible = false
	window.force_native = true
	window.borderless = true
	window.transparent = true
	window.transparent_bg = true
	window.files_dropped.connect(files_dropped.emit)
	_layer.add_child(window)
	window.add_child(pane)
	pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	window.position = get_window().position + Vector2i(get_window().size.x, 0)
	window.visible = true
	_windows[key] = window
	_panes[key] = pane
	return window

func _window_command(window: Window, command: Array) -> void:
	match command[0]:
		"drag":
			DisplayServer.window_start_drag(window.get_window_id())
		"minimize":
			for each: Window in [get_window()] + _windows.values():
				each.mode = Window.MODE_MINIMIZED
		"resize":
			DisplayServer.window_start_resize(int(command[1]) as DisplayServer.WindowResizeEdge, window.get_window_id())

func _command(name: String, value: Variant) -> void:
	var playing := MediaPlayer.is_playing()
	match name:
		"play":
			if not playing:
				MediaPlayer.toggle()
		"pause":
			if playing:
				MediaPlayer.toggle()
		"stop":
			if playing:
				MediaPlayer.toggle()
			MediaPlayer.seek(0)
		"next":
			MediaPlayer.next()
		"previous":
			MediaPlayer.previous()
		"seek":
			MediaPlayer.seek(int(value) * 1000)
		"seek_by":
			MediaPlayer.seek(clampi(MediaPlayer.get_position() + int(value), 0, MediaPlayer.get_duration()))
		"volume", "preview_volume":
			MediaPlayer.set_volume(clampf(float(value) / 100.0, 0.0, 1.0))
		"mute":
			if value:
				_volume = maxf(float(SettingsManager.playback.volume), 0.05)
			MediaPlayer.set_volume(0.0 if value else _volume)
		"balance":
			SettingsManager.playback.balance = clampf(float(value), -100.0, 100.0)
		"shuffle":
			MediaPlayer.shuffle(bool(value))
		"repeat":
			MediaPlayer.repeat(MediaPlayer.Repeat.ALL if value else MediaPlayer.Repeat.OFF)
		"play_queued":
			MediaPlayer.skip_to_queue_index(int(value))
		"eq_band":
			SettingsManager.equalizer.enabled = true
			Equalizer.set_gain(int(value[0]), float(value[1]))
		"eq_preamp":
			Equalizer.set_preamp(float(value))
		"eq_on":
			SettingsManager.equalizer.enabled = bool(value)
		"eq_preset":
			var presets: Array = Equalizer.presets().keys()
			if int(value) >= 0 and int(value) < presets.size():
				Equalizer.load_preset(presets[int(value)])
		"eq_reset":
			Equalizer.reset()
		"back":
			closed.emit()
		"effect":
			_step_effect(int(value))
		"sound":
			_sound(str(value))
		"open_file":
			DisplayServer.file_dialog_show("Open media", OS.get_system_dir(OS.SYSTEM_DIR_MUSIC), "", false, DisplayServer.FILE_DIALOG_MODE_OPEN_FILES, PackedStringArray(AUDIO), func(status: bool, paths: PackedStringArray, _filter: int):
				if status:
					MediaPlayer.open_files(paths))
		"play_list":
			_play_list(value[0], int(value[1]))

func _texture(picture: int, frame: int) -> Texture2D:
	var cache := "%d:%d" % [picture, frame]
	if not _textures.has(cache):
		var pixels: Dictionary = _skin.frame(picture, frame)
		if pixels.is_empty():
			return null
		_textures[cache] = ImageTexture.create_from_image(Image.create_from_data(pixels["width"], pixels["height"], false, Image.FORMAT_RGBA8, pixels["rgba"]))
	return _textures[cache]

func draw_op(item: RID, op: Dictionary, unit: float) -> void:
	var area := Rect2(Vector2(op["area"].position) * unit, Vector2(op["area"].size) * unit)
	match op["kind"]:
		"picture":
			var texture := _texture(op["picture"], op["frame"])
			if texture:
				RenderingServer.canvas_item_add_texture_rect_region(item, area, texture.get_rid(), Rect2(op["part"]), Color(1, 1, 1, op["alpha"] / 255.0))
		"fill":
			RenderingServer.canvas_item_add_rect(item, area, op["color"])
		"text":
			_draw_text(item, op, area, unit)
		"wave":
			var step := area.size.x / _wave.size()
			for column in _wave.size():
				var height := maxf(_wave[column] * area.size.y, unit)
				RenderingServer.canvas_item_add_rect(item, Rect2(area.position.x + step * column, area.get_center().y - height * 0.5, maxf(step * 0.5, unit), height), op["color"])
		"art":
			if op.has("color"):
				RenderingServer.canvas_item_add_rect(item, area, op["color"])
			if _art:
				var side := minf(area.size.x, area.size.y)
				RenderingServer.canvas_item_add_texture_rect(item, Rect2(area.get_center() - Vector2.ONE * side * 0.5, Vector2.ONE * side), _art.get_rid())

func _draw_text(item: RID, op: Dictionary, area: Rect2, unit: float) -> void:
	var font: Font = _fonts["mono" if op["mono"] else "bold" if op["bold"] else "regular"]
	var size := maxi(roundi(float(op["size"]) * unit), 1)
	var text := str(op["text"])
	var color: Color = op["color"]
	var align := int(op["align"])
	var top := area.position.y + font.get_ascent(size)
	if op["wrap"]:
		font.draw_multiline_string(item, Vector2(area.position.x, top), text, [HORIZONTAL_ALIGNMENT_LEFT, HORIZONTAL_ALIGNMENT_CENTER, HORIZONTAL_ALIGNMENT_RIGHT][align + 1], area.size.x, size, -1, color)
		return
	var line := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var start := roundf(area.position.x + [0.0, (area.size.x - line) * 0.5, area.size.x - line][align + 1] - float(op["scroll"]) * unit)
	font.draw_string(item, Vector2(start, roundf(top)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
	if float(op["scroll"]) != 0.0:
		font.draw_string(item, Vector2(start + signf(float(op["scroll"])) * (line + GAP * unit), roundf(top)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
	var thick := maxf(size / 14.0, 1.0)
	if op["underline"]:
		RenderingServer.canvas_item_add_rect(item, Rect2(start, top + thick, line, thick), color)
	if op["strikeout"]:
		RenderingServer.canvas_item_add_rect(item, Rect2(start, top - size * 0.3, line, thick), color)

func leave(pane: WmpPane) -> void:
	_skin.input(pane.key, "left", 0.0, 0.0, 0, false, false, false)

func handle(pane: WmpPane, event: InputEvent) -> bool:
	var key := pane.key
	var unit := pane.size.x / maxf(Vector2(_sizes.get(key, Vector2i.ONE)).x, 1.0)
	var shift: bool = event is InputEventWithModifiers and event.shift_pressed
	var ctrl: bool = event is InputEventWithModifiers and (event.ctrl_pressed or event.meta_pressed)
	var alt: bool = event is InputEventWithModifiers and event.alt_pressed
	_last = pane
	if event is InputEventMouse:
		var point: Vector2 = event.position / unit
		_skin.input(key, "pointer", point.x, point.y, 0, shift, ctrl, alt)
	if event is InputEventMouseMotion:
		return true
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		if event.pressed:
			_skin.input(key, "wheel", 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0, 0.0, 0, shift, ctrl, alt)
		return true
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		var secondary: bool = event.button_index == MOUSE_BUTTON_RIGHT
		if event.pressed:
			pane.grab_focus()
		_skin.input(key, "press" if event.pressed else "release", 0.0, 0.0, int(secondary), shift, ctrl, alt)
		if secondary and not event.pressed:
			SkinMenu.popup(pane, _menu(), SkinMenu.nari_colors(), null, zoom * 2)
		return true
	if event is InputEventKey:
		var code: int = event.keycode if event.keycode >= KEY_A and event.keycode <= KEY_Z or event.keycode >= KEY_0 and event.keycode <= KEY_9 else KEYS.get(event.keycode, 0)
		if code > 0 and not event.echo:
			_skin.input(key, "key_down" if event.pressed else "key_up", 0.0, 0.0, code, shift, ctrl, alt)
		if event.pressed and event.unicode >= 32:
			_skin.input(key, "character", 0.0, 0.0, event.unicode, shift, ctrl, alt)
		return code > 0 or event.unicode >= 32
	return false

func _store(key: String, value: Variant) -> void:
	set(key, value)
	SettingsManager.set_value(SECTION, "wmp_zoom" if key == "zoom" else key, value)

func _menu() -> Array:
	var sizes: Array = range(1, 4).map(func(size: int): return ["Size %dx" % size, _store.bind("zoom", size), zoom == size])
	return [
		["Visualization", [["Visualizer", SkinMenu.visuals(_visual if _effect == "visualizer" else -1, func(target: int): _set_effect("visualizer", target))], ["Lyrics", _set_effect.bind("lyrics"), _effect == "lyrics"], ["Album art", _set_effect.bind("cover"), _effect == "cover"]]],
		["Skins", SkinMenu.skins(skin_requested.emit)],
		["Options", [["Always on top", func(): _store("on_top", not on_top), on_top], []] + sizes],
	]
