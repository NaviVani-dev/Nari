class_name WinampPlayer extends WinampView

signal closed
signal skin_requested(source: String)
signal files_dropped(files: PackedStringArray)

const SNAP := 10
const LAYER := 120
const CONTENT_SCALE := 0.3
const DRAGGED: Array[String] = ["volume", "balance", "position", "seek", "eq_volume", "eq_balance", "pl_scroll", "pl_resize", "vis_resize"]
const TITLES := {"title": "shade", "eq_title": "eq_shade", "pl_title": "pl_shade"}

var _panes := {}
var _windows := {}
var _layer := CanvasLayer.new()
var _veiled := false
var _move := {}
var _stretch := {}
var _last: Control
var _content := SkinContent.new(true)

func _ready() -> void:
	_levels.resize(BARS)
	_peaks.resize(BARS)
	_wave.resize(76)
	for key in KEYS:
		set(key, SettingsManager.get_value(SECTION, key, get(key)))
	_layer.layer = LAYER
	get_tree().root.add_child(_layer)
	_veil.call_deferred()
	_add_pane("main", _layer)
	for kind in ["eq", "pl", "vis"]:
		var window := Window.new()
		window.visible = false
		window.force_native = true
		window.title = {"eq": "Equalizer", "pl": "Playlist editor", "vis": "Visualization"}[kind]
		window.borderless = true
		window.unresizable = true
		window.focus_entered.connect(_redraw)
		window.focus_exited.connect(_redraw)
		window.files_dropped.connect(files_dropped.emit)
		window.close_requested.connect(_activate.bind(kind + "_close"))
		_layer.add_child(window)
		_windows[kind] = window
		_add_pane(kind, window)
	_panes["vis"].add_child(_content)
	_windows["vis"].size_changed.connect(_fit_content)
	get_window().focus_entered.connect(_redraw)
	get_window().focus_exited.connect(_redraw)
	MediaPlayer.playback_changed.connect(_on_playback)
	Main.tray_changed.connect(func(hidden: bool):
		for kind: String in _windows:
			_windows[kind].visible = not hidden and get(kind + "_open"))
	if layout.has("main"):
		get_window().position = Vector2i(layout["main"][0], layout["main"][1])
	_on_playback(MediaPlayer.get_playback_state())
	_sync()
	_keep_on_screen()

func _exit_tree() -> void:
	if _veiled:
		SkinMenu.unveil()
	_layer.queue_free()

func _add_pane(kind: String, parent: Node) -> void:
	var pane := WinampPane.new(self, kind)
	parent.add_child(pane)
	pane.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_panes[kind] = pane

func _veil() -> void:
	if is_inside_tree() and not _veiled:
		_veiled = true
		SkinMenu.veil(get_tree())

func focus() -> void:
	_panes["main"].grab_focus()

func _skin_changed() -> void:
	_redraw()

func store(key: String, value: Variant) -> void:
	set(key, value)
	SettingsManager.set_value(SECTION, key, value)
	_sync()

func _redraw() -> void:
	for pane: Control in _panes.values():
		pane.queue_redraw()

func _sync() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	get_window().min_size = Vector2i.ONE
	Main.resize_mini(Vector2i(pane_size("main") * zoom))
	get_window().always_on_top = on_top
	for kind: String in _windows:
		var window: Window = _windows[kind]
		window.always_on_top = on_top
		if not (kind == "vis" and vis_full):
			window.size = Vector2i(pane_size(kind) * zoom)
		if window.visible != bool(get(kind + "_open")):
			window.visible = get(kind + "_open")
	_place()
	_fit_content()
	_redraw()

func _offset(kind: String) -> Vector2i:
	var spot: Array = layout.get(kind, [0, 0])
	return Vector2i(roundi(float(spot[0]) * zoom), roundi(float(spot[1]) * zoom))

func _place() -> void:
	var origin := get_window().position
	for kind: String in _windows:
		if not (kind == "vis" and vis_full):
			_windows[kind].position = origin + _offset(kind)

func _rect(kind: String) -> Rect2i:
	var window: Window = get_window() if kind == "main" else _windows[kind]
	return Rect2i(window.position, window.size)

func _open() -> Array[String]:
	var kinds: Array[String] = ["main"]
	for kind: String in _windows:
		if _windows[kind].visible and not (kind == "vis" and vis_full):
			kinds.append(kind)
	return kinds

func _touching(a: Rect2i, b: Rect2i) -> bool:
	var stacked := (absi(a.end.y - b.position.y) <= 1 or absi(b.end.y - a.position.y) <= 1) and a.position.x < b.end.x and b.position.x < a.end.x
	var beside := (absi(a.end.x - b.position.x) <= 1 or absi(b.end.x - a.position.x) <= 1) and a.position.y < b.end.y and b.position.y < a.end.y
	return stacked or beside

func _group() -> Array[String]:
	var group: Array[String] = ["main"]
	var index := 0
	while index < group.size():
		for kind in _open():
			if not kind in group and _touching(_rect(group[index]), _rect(kind)):
				group.append(kind)
		index += 1
	return group

func _below(kind: String) -> Array[String]:
	var chain: Array[String] = [kind]
	var index := 0
	while index < chain.size():
		var rect := _rect(chain[index])
		for other in _open():
			var under := _rect(other)
			if not other in chain and other != "main" and absi(under.position.y - rect.end.y) <= 1 and under.position.x < rect.end.x and rect.position.x < under.end.x:
				chain.append(other)
		index += 1
	chain.erase(kind)
	return chain

func _snap(rect: Rect2i, others: Array[Rect2i]) -> Vector2i:
	var best := Vector2i(SNAP + 1, SNAP + 1)
	var area := DisplayServer.screen_get_usable_rect(get_window().current_screen)
	var pick := func(current: int, options: Array) -> int:
		for option: int in options:
			if absi(option) < absi(current):
				current = option
		return current
	best.x = pick.call(best.x, [area.position.x - rect.position.x, area.end.x - rect.end.x])
	best.y = pick.call(best.y, [area.position.y - rect.position.y, area.end.y - rect.end.y])
	for other in others:
		if rect.position.y <= other.end.y + SNAP and rect.end.y >= other.position.y - SNAP:
			best.x = pick.call(best.x, [other.position.x - rect.end.x, other.end.x - rect.position.x, other.position.x - rect.position.x, other.end.x - rect.end.x])
		if rect.position.x <= other.end.x + SNAP and rect.end.x >= other.position.x - SNAP:
			best.y = pick.call(best.y, [other.position.y - rect.end.y, other.end.y - rect.position.y, other.position.y - rect.position.y, other.end.y - rect.end.y])
	return Vector2i(best.x if absi(best.x) <= SNAP else 0, best.y if absi(best.y) <= SNAP else 0)

func _begin_move(kind: String) -> void:
	_move = {"kind": kind, "mouse": DisplayServer.mouse_get_position(), "group": _group() if kind == "main" else [kind], "root": get_window().position, "layout": layout.duplicate(true)}

func _moving() -> void:
	var kind: String = _move["kind"]
	var group: Array = _move["group"]
	var start: Vector2i = _move["root"]
	var delta: Vector2i = DisplayServer.mouse_get_position() - _move["mouse"]
	if kind != "main":
		var spot: Array = _move["layout"][kind]
		start += Vector2i(roundi(float(spot[0]) * zoom), roundi(float(spot[1]) * zoom))
	var others: Array[Rect2i] = []
	for other in _open():
		if not other in group:
			others.append(_rect(other))
	delta += _snap(Rect2i(start + delta, _rect(kind).size), others)
	if kind == "main":
		get_window().position = start + delta
		for other: String in _windows:
			if not other in group:
				var spot: Array = _move["layout"][other]
				layout[other] = [float(spot[0]) - delta.x / float(zoom), float(spot[1]) - delta.y / float(zoom)]
	else:
		var spot: Array = _move["layout"][kind]
		layout[kind] = [float(spot[0]) + delta.x / float(zoom), float(spot[1]) + delta.y / float(zoom)]
	_place()

func _save_layout() -> void:
	layout["main"] = [get_window().position.x, get_window().position.y]
	SettingsManager.set_value(SECTION, "layout", layout)

func _keep_on_screen() -> void:
	var bounds := _rect("main")
	for kind in _open():
		bounds = bounds.merge(_rect(kind))
	var area := DisplayServer.screen_get_usable_rect(get_window().current_screen)
	var shift := Vector2i(clampi(bounds.position.x, area.position.x, maxi(area.end.x - bounds.size.x, area.position.x)), clampi(bounds.position.y, area.position.y, maxi(area.end.y - bounds.size.y, area.position.y))) - bounds.position
	if shift != Vector2i.ZERO:
		get_window().position += shift
		_place()
	_save_layout()

func _reshape(kind: String, key: String, value: Variant) -> void:
	var height := _rect(kind).size.y
	var chain := _below(kind)
	store(key, value)
	var grow := (pane_size(kind).y * zoom - height) / float(zoom)
	for other in chain:
		layout[other] = [float(layout[other][0]), float(layout[other][1]) + grow]
	_place()
	_save_layout()

func _fit_content() -> void:
	var pane: Control = _panes["vis"]
	var scale := CONTENT_SCALE * zoom
	var inner := Rect2(Vector2.ZERO, Vector2(_windows["vis"].size)) if vis_full else Rect2(Vector2(11, 20) * zoom, (pane_size("vis") - Vector2(19, 34)) * zoom)
	_content.position = inner.position
	_content.scale = Vector2.ONE * scale
	_content.size = inner.size / scale
	_content.show_view(vis_view, vis_visual, vis_open)
	pane.queue_redraw()

func _process(delta: float) -> void:
	var data := MediaPlayer.get_spectrum() if MediaPlayer.is_playing() else PackedByteArray()
	var live := data.size() >= 161
	for bar in BARS:
		var target := float(data[int(bar * 31.0 / (BARS - 1))]) / 255.0 if live else 0.0
		_levels[bar] = maxf(target, _levels[bar] - delta * 2.2)
		_peaks[bar] = maxf(_levels[bar], _peaks[bar] - delta * 0.6)
	for index in _wave.size():
		_wave[index] = (float(data[32 + int(index * 127.0 / 75.0)]) - 128.0) / 128.0 if live else 0.0
	_marquee_left -= delta
	if _marquee_left <= 0.0:
		_marquee_left = MARQUEE_TICK
		_marquee += 1
	if _message_left > 0.0:
		_message_left -= delta
	_redraw()

func _on_playback(state: Dictionary) -> void:
	_current = int(state.get("index", -1))
	var version := int(state.get("queue_version", 0))
	if version != _queue_version:
		_queue_version = version
		_queue = await MediaPlayer.get_queue()
		_selected.clear()
		_scroll = clampi(_current - 2, 0, maxi(_queue.size() - _visible_rows(), 0))
	_redraw()

func _say(text: String) -> void:
	_message = text
	_message_left = MESSAGE_TIME

func _areas(kind: String, size: Vector2) -> Dictionary:
	var right := size.x
	match kind:
		"main":
			return MAIN_SHADED if shaded else MAIN
		"eq":
			if eq_shaded:
				return EQ_SHADED
			var bands := EQ.duplicate()
			for band in 10:
				bands["band_%d" % band] = _band_rect(band)
			return bands
		"vis":
			return {"vis_close": Rect2(right - 11, 3, 9, 9), "vis_resize": Rect2(right - 20, size.y - 20, 20, 20), "vis_content": Rect2(11, 20, right - 19, size.y - 34), "vis_title": Rect2(0, 0, right, 20)}
	if pl_shaded:
		return {"pl_close": Rect2(right - 11, 3, 9, 9), "pl_unshade": Rect2(right - 21, 3, 9, 9), "pl_title": Rect2(0, 0, right, 14)}
	var areas := {"pl_close": Rect2(right - 11, 3, 9, 9), "pl_shade": Rect2(right - 21, 3, 9, 9), "pl_list": Rect2(12, 20, right - 32, size.y - 58), "pl_scroll": Rect2(right - 17, 20, 12, size.y - 58), "pl_resize": Rect2(right - 20, size.y - 20, 20, 20)}
	for id: String in PL_MENUS:
		areas[id] = Rect2(PL_MENUS[id], size.y - 30, 22, 18)
	areas["pl_options"] = Rect2(right - 47, size.y - 30, 22, 18)
	for slot in PL_TRANSPORT.size():
		areas[PL_TRANSPORT[slot]] = Rect2(right - 146 + 10 * slot, size.y - 16, 10, 10)
	areas["pl_title"] = Rect2(0, 0, right, 20)
	return areas

func _hit(kind: String, point: Vector2) -> String:
	if kind == "vis" and vis_full:
		return "vis_content"
	var areas := _areas(kind, pane_size(kind))
	for id: String in areas:
		if (areas[id] as Rect2).has_point(point):
			return id
	return "drag"

func handle(pane: Control, event: InputEvent) -> bool:
	var kind: String = pane.kind
	var point: Vector2 = event.position / unit(pane) if event is InputEventMouse else Vector2.ZERO
	_last = pane
	if event is InputEventMouseButton and event.pressed:
		pane.grab_focus()
	if event is InputEventMouseButton and event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var up: bool = event.button_index == MOUSE_BUTTON_WHEEL_UP
		if kind == "pl":
			_scroll = clampi(_scroll + (-3 if up else 3), 0, maxi(_queue.size() - _visible_rows(), 0))
		elif kind != "vis":
			MediaPlayer.set_volume(clampf(SettingsManager.playback.volume + (0.05 if up else -0.05), 0.0, 1.0))
		else:
			return false
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		_popup(_vis_menu() if kind == "vis" else _main_menu())
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_press(kind, _hit(kind, point), point, event)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not _move.is_empty():
			_move = {}
			_save_layout()
		elif not _dragging.is_empty():
			_slide(_dragging, point, true)
		elif not _pressed.is_empty() and _hit(kind, point) == _pressed:
			_activate(_pressed)
		_dragging = ""
		_pressed = ""
	elif event is InputEventMouseMotion and not _move.is_empty():
		_moving()
	elif event is InputEventMouseMotion and not _dragging.is_empty():
		_slide(_dragging, point, false)
	elif event is InputEventKey and event.pressed and not event.echo and not _shortcut(event).is_empty():
		_activate(_shortcut(event))
	elif event.is_action_pressed("ui_left", true) or event.is_action_pressed("ui_right", true):
		MediaPlayer.seek(clampi(MediaPlayer.get_position() + (5000 if event.is_action("ui_right") else -5000), 0, MediaPlayer.get_duration()))
	elif event.is_action_pressed("ui_up", true) or event.is_action_pressed("ui_down", true):
		MediaPlayer.set_volume(clampf(SettingsManager.playback.volume + (0.05 if event.is_action("ui_up") else -0.05), 0.0, 1.0))
		_say("VOLUME: %d%%" % roundi(SettingsManager.playback.volume * 100))
	elif event.is_action_pressed("ui_accept"):
		_activate("pause")
	else:
		return false
	_redraw()
	return true

func _shortcut(event: InputEventKey) -> String:
	var keys: Dictionary = {KEY_E: "pl", KEY_G: "eq"} if event.alt_pressed else {KEY_D: "clutter_d", KEY_T: "time", KEY_A: "clutter_a", KEY_K: "vis"} if event.ctrl_pressed else {KEY_Z: "previous", KEY_X: "play", KEY_C: "pause", KEY_V: "stop", KEY_B: "next"}
	return keys.get(event.keycode, "")

func _press(kind: String, id: String, point: Vector2, event: InputEventMouseButton) -> void:
	if id in ["drag", "vis_title"] or TITLES.has(id):
		if event.double_click and TITLES.has(id):
			_activate(TITLES[id])
		else:
			_begin_move(kind)
	elif id == "vis_content":
		if event.double_click:
			_activate("vis_full")
	elif id == "pl_list":
		_pick(int((point.y - 20.0) / ROW) + _scroll, event)
	elif id in DRAGGED or id.begins_with("band_"):
		_dragging = id
		if id.ends_with("_resize"):
			var prefix := id.get_slice("_", 0)
			_stretch = {"mouse": DisplayServer.mouse_get_position(), "cols": get(prefix + "_cols"), "rows": get(prefix + "_rows")}
		_slide(id, point, false)
	else:
		_pressed = id

func _pick(index: int, event: InputEventMouseButton) -> void:
	if index >= _queue.size():
		_selected.clear()
		return
	if event.double_click:
		MediaPlayer.skip_to_queue_index(index)
		return
	if event.shift_pressed and _anchor >= 0:
		for between in range(mini(_anchor, index), maxi(_anchor, index) + 1):
			_selected[between] = true
		return
	if not (event.ctrl_pressed or event.meta_pressed):
		_selected.clear()
	if _selected.has(index):
		_selected.erase(index)
	else:
		_selected[index] = true
	_anchor = index

func _slide(id: String, local: Vector2, final: bool) -> void:
	match id:
		"volume", "eq_volume":
			var value := clampf((local.x - (114.0 if id == "volume" else 62.0)) / (54.0 if id == "volume" else 94.0), 0.0, 1.0)
			MediaPlayer.set_volume(value)
			_say("VOLUME: %d%%" % roundi(value * 100))
		"balance", "eq_balance":
			var value := clampf((local.x - (184.0 if id == "balance" else 165.0)) / (24.0 if id == "balance" else 40.0) * 2.0 - 1.0, -1.0, 1.0)
			var balance := 0.0 if absf(value) < CENTER else value
			SettingsManager.playback.balance = roundf(balance * 100.0)
			_say("BALANCE: CENTER" if balance == 0.0 else "BALANCE: %d%% %s" % [roundi(absf(balance) * 100), "LEFT" if balance < 0.0 else "RIGHT"])
		"position", "seek":
			_seek = clampf((local.x - (30.0 if id == "position" else 227.0)) / (219.0 if id == "position" else 14.0), 0.0, 1.0)
			_say("SEEK TO: %s/%s (%d%%)" % [MediaPlayer.format_duration(int(_seek * MediaPlayer.get_duration())), MediaPlayer.format_duration(MediaPlayer.get_duration()), roundi(_seek * 100)])
			if final:
				MediaPlayer.seek(int(_seek * MediaPlayer.get_duration()))
				_seek = -1.0
				_message_left = 0.0
		"pl_scroll":
			var room := maxi(_queue.size() - _visible_rows(), 0)
			_scroll = clampi(roundi((local.y - 29.0) / maxf(pane_size("pl").y - 76.0, 1.0) * room), 0, room)
		"pl_resize", "vis_resize":
			var prefix := id.get_slice("_", 0)
			var moved := Vector2(DisplayServer.mouse_get_position() - (_stretch["mouse"] as Vector2i)) / zoom
			var cols := clampi(int(_stretch["cols"]) + roundi(moved.x / TILE), 0, MAX_STEPS)
			var rows := clampi(int(_stretch["rows"]) + roundi(moved.y / STEP), 0, MAX_STEPS)
			if cols != get(prefix + "_cols") or rows != get(prefix + "_rows"):
				set(prefix + "_cols", cols)
				SettingsManager.set_value(SECTION, prefix + "_cols", cols)
				store(prefix + "_rows", rows)
		_:
			var band := id.trim_prefix("band_").to_int()
			var gain := snappedf((1.0 - clampf((local.y - 43.0) / 51.0, 0.0, 1.0)) * 24.0 - 12.0, 0.5)
			gain = 0.0 if absf(gain) < 1.0 else gain
			if band < 0:
				Equalizer.set_preamp(gain)
			else:
				Equalizer.set_gain(band, gain)
			_say("%s: %s DB" % ["PREAMP" if band < 0 else "EQ: %sHZ" % Equalizer.LABELS[band], Equalizer.format_gain(gain)])

func _activate(id: String) -> void:
	var song := MediaPlayer.get_current_song()
	match id:
		"previous":
			MediaPlayer.previous()
		"play":
			if MediaPlayer.is_playing():
				MediaPlayer.seek(0)
			elif not song.is_empty():
				MediaPlayer.toggle()
		"pause":
			if not song.is_empty():
				MediaPlayer.toggle()
		"stop":
			if MediaPlayer.is_playing():
				MediaPlayer.toggle()
			MediaPlayer.seek(0)
		"next":
			MediaPlayer.next()
		"eject", "pl_add":
			_popup([["Shuffle library", func(): MediaPlayer.play_tracks(await MediaPlayer.get_tracks(), "", true)], ["Liked songs", func(): MediaPlayer.play_tracks(await MediaPlayer.get_liked("track"))], ["Song radio", MediaPlayer.start_radio.bind("track", song)]])
		"shuffle":
			MediaPlayer.shuffle()
		"repeat":
			MediaPlayer.repeat()
		"eq", "pl", "vis":
			store(id + "_open", not get(id + "_open"))
		"eq_close", "pl_close", "vis_close":
			if id == "vis_close" and vis_full:
				_activate("vis_full")
			store(id.get_slice("_", 0) + "_open", false)
		"options", "clutter_o":
			_popup(_main_menu())
		"minimize":
			for window: Window in [get_window()] + _windows.values():
				if window.visible:
					window.mode = Window.MODE_MINIMIZED
		"shade", "unshade":
			_reshape("main", "shaded", not shaded)
		"eq_shade", "eq_unshade":
			_reshape("eq", "eq_shaded", not eq_shaded)
		"pl_shade", "pl_unshade":
			_reshape("pl", "pl_shaded", not pl_shaded)
		"close":
			Main.leave_mini()
		"about":
			closed.emit()
		"clutter_a":
			store("on_top", not on_top)
		"clutter_i", "pl_misc":
			var picked: Dictionary = _queue[_selected.keys().min()] if id == "pl_misc" and not _selected.is_empty() and _selected.keys().min() < _queue.size() else song
			_popup(_song_menu(picked))
		"clutter_d":
			store("zoom", zoom % 4 + 1)
		"clutter_v", "analyzer":
			store("vis_mode", (vis_mode + 1) % 3)
		"time":
			store("remaining", not remaining)
		"mono":
			SettingsManager.playback.mono = not SettingsManager.playback.mono
			_say("MONO" if SettingsManager.playback.mono else "STEREO")
		"eq_switch":
			SettingsManager.equalizer.enabled = not SettingsManager.equalizer.enabled
		"eq_auto":
			SettingsManager.equalizer.auto = not SettingsManager.equalizer.auto
		"eq_presets":
			var presets: Array = Equalizer.presets().keys().map(func(preset: String): return [preset, Equalizer.load_preset.bind(preset), preset == Equalizer.current_preset()])
			_popup([["Load", presets], ["Save preset", _ask_preset], [], ["Reset", Equalizer.reset]])
		"pl_rem":
			_popup([["Remove selected", _remove_selected], ["Clear upcoming", MediaPlayer.clear_upcoming]])
		"pl_sel":
			_popup([["Select all", _select.bind(func(_index: int): return true)], ["Select none", _select.bind(func(_index: int): return false)], ["Invert selection", _select.bind(func(index: int): return not _selected.has(index))]])
		"pl_options":
			_popup((await MediaPlayer.get_playlists()).map(func(playlist: Dictionary): return [str(playlist.get("name", "")), func(): MediaPlayer.play_tracks((await MediaPlayer.get_playlist(str(playlist.get("id", "")))).get("tracks", []))]))
		"vis_full":
			vis_full = not vis_full
			_windows["vis"].mode = Window.MODE_FULLSCREEN if vis_full else Window.MODE_WINDOWED
			_sync()

func _select(keep: Callable) -> void:
	var picked := {}
	for index in _queue.size():
		if keep.call(index):
			picked[index] = true
	_selected = picked
	_redraw()

func _remove_selected() -> void:
	var indices: Array = _selected.keys()
	indices.sort()
	indices.reverse()
	for index: int in indices:
		MediaPlayer.remove_from_queue(index)
	_selected.clear()

func _main_menu() -> Array:
	var skins := SkinMenu.skins(skin_requested.emit)
	var sizes: Array = range(1, 5).map(func(size: int): return ["Size %dx" % size, store.bind("zoom", size), zoom == size])
	return [
		["Nari view", closed.emit], [],
		["Equalizer", _activate.bind("eq"), eq_open], ["Playlist editor", _activate.bind("pl"), pl_open], ["Visualization", _activate.bind("vis"), vis_open], [],
		["Skins", skins],
		["Options", [["Always on top", _activate.bind("clutter_a"), on_top], ["Time remaining", _activate.bind("time"), remaining], []] + sizes],
		["Playback", [["Previous", _activate.bind("previous")], ["Play", _activate.bind("play")], ["Pause", _activate.bind("pause")], ["Stop", _activate.bind("stop")], ["Next", _activate.bind("next")], [],
			["Shuffle", _activate.bind("shuffle"), MediaPlayer.is_shuffled()], ["Repeat", _activate.bind("repeat"), MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF]]],
		["Analyzer", [["Spectrum analyzer", store.bind("vis_mode", 0), vis_mode == 0], ["Oscilloscope", store.bind("vis_mode", 1), vis_mode == 1], ["Off", store.bind("vis_mode", 2), vis_mode == 2]]],
	]

func _vis_menu() -> Array:
	return [
		["Visualizer", SkinMenu.visuals(vis_visual if vis_view == "visualizer" else -1, func(target: int):
			vis_view = "visualizer"
			SettingsManager.set_value(SECTION, "vis_view", vis_view)
			store("vis_visual", target))],
		["Lyrics", store.bind("vis_view", "lyrics"), vis_view == "lyrics"],
		["Album art", store.bind("vis_view", "cover"), vis_view == "cover"], [],
		["Fullscreen", _activate.bind("vis_full"), vis_full],
		["Close", _activate.bind("vis_close")],
	]

func _song_menu(song: Dictionary) -> Array:
	if song.is_empty():
		return []
	var liked := MediaPlayer.is_liked("track", str(song.get("id", "")))
	var items: Array = [[ItemMenu.like_text("track", liked), MediaPlayer.set_liked.bind("track", song, not liked)], ["Start song radio", MediaPlayer.start_radio.bind("track", song)]]
	if not str(song.get("artist_id", "")).is_empty():
		items.append(["Go to artist", Main.change_page.bind(Main.Pages.Artist, {"artist_id": str(song.get("artist_id", ""))})])
	if not str(song.get("album_id", "")).is_empty():
		items.append(["Go to album", Main.change_page.bind(Main.Pages.Album, {"album_id": str(song.get("album_id", ""))})])
	if str(song.get("share_url", "")).begins_with("https://"):
		items.append(["Copy link", DisplayServer.clipboard_set.bind(str(song.get("share_url", "")))])
	return items

func _ask_preset() -> void:
	var ask := AcceptDialog.new()
	var field := LineEdit.new()
	ask.title = "Save preset"
	ask.ok_button_text = "Save"
	ask.force_native = true
	ask.theme = SkinMenu.theme(_host(), skin.menu_colors(), skin.font, zoom)
	field.placeholder_text = "Preset name"
	ask.add_child(field)
	ask.register_text_enter(field)
	ask.confirmed.connect(func(): Equalizer.save_preset(field.text))
	ask.visibility_changed.connect(func():
		if not ask.visible:
			ask.queue_free())
	_host().add_child(ask)
	ask.popup_centered(Vector2i(360, 90))
	field.grab_focus.call_deferred()

func _host() -> Control:
	return _last if is_instance_valid(_last) else _panes["main"]

func _popup(items: Array) -> void:
	SkinMenu.popup(_host(), items, skin.menu_colors(), skin.font, zoom)
