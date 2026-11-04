extends Page

const COVER := preload("res://ui/shared/Cover.tscn")
const LYRICS := preload("res://ui/components/LyricsVisualizer.tscn")
const EMPTY_MESSAGE := preload("res://ui/shared/EmptyMessage.tscn")
const MORE_ICON := preload("res://assets/icons/more.svg")
const SHUFFLE_ICON := preload("res://assets/icons/shuffle.svg")
const PREVIOUS_ICON := preload("res://assets/icons/skip_previous.svg")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const NEXT_ICON := preload("res://assets/icons/skip_next.svg")
const REPEAT_ICON := preload("res://assets/icons/repeat.svg")
const REPEAT_ONE_ICON := preload("res://assets/icons/repeat_one.svg")
const BACK_ICON := preload("res://assets/icons/chevron_left.svg")
const COVER_ICON := preload("res://assets/icons/album.svg")
const LYRICS_ICON := preload("res://assets/icons/lyrics.svg")
const QUEUE_ICON := preload("res://assets/icons/queue_music.svg")
const VISUALIZER_ICON := preload("res://assets/icons/visualizer.svg")
const SONG_ICON := preload("res://assets/icons/music_note.svg")
const SKIN_ICON := preload("res://assets/icons/theme.svg")
const FOLDER_ICON := preload("res://assets/icons/new_folder.svg")
const VOLUME := preload("res://ui/shared/VolumeButton.tscn")
const BUTTON_SIZE := 139.0
const PLAY_SIZE := 188.0
const TAB_SIZE := 88.0
const HEADER_SCALE := 2.0 / 3.0
const DOCK_MAX := 1000.0
const PADDING := 40
const SHADE_TOP := 0.16
const SHADE_BOTTOM := 0.5
const IDLE_TIME := 2.5
const FADE_TIME := 0.3

var transient := true

@onready var visualizers: Visualizers = %Visualizers
@onready var skin_holder: Control = %Skin
@onready var stage: Control = %Stage
@onready var overlay: Control = %Overlay

var _cover: Cover = COVER.instantiate()
var _lyrics: LyricsVisualizer = LYRICS.instantiate()
var _queue := StairScroll.new()
var _queue_empty: EmptyMessage = EMPTY_MESSAGE.instantiate()
var _title := NariLabel.new()
var _current := NariLabel.new()
var _total := NariLabel.new()
var _slider := ProgressSlider.new()
var _shuffle := _button(SHUFFLE_ICON, func(): MediaPlayer.shuffle(), BUTTON_SIZE, 64.0)
var _play := _button(PLAY_ICON, MediaPlayer.toggle, PLAY_SIZE, 98.0)
var _repeat := _button(REPEAT_ICON, func(): MediaPlayer.repeat(), BUTTON_SIZE, 64.0)
var _slot := Control.new()
var _dock := VBoxContainer.new()
var _idle := Timer.new()
var _fade: Tween
var _views := {}
var _view := ""
var _visualizer := -1
var _seeking := false
var _song_id := ""
var _queue_start := 0
var _elapsed := 0.0
var _winamp: WinampPlayer
var _wmp: WmpPlayer

func _ready() -> void:
	_cover.crop = true
	_cover.corner_radius = 0
	_cover.show_shadow = false
	_cover.wave_transitions = true
	_cover.mouse_filter = Control.MOUSE_FILTER_PASS
	_queue.step = 0.0
	_queue.follow_focus = true
	_queue.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_queue.allow_horizontal_scroll = false
	_queue_empty.show_message([QUEUE_ICON, "Queue empty!", "Songs you add to the queue show up here"])
	_views = {"": _cover, "lyrics": _margin(_lyrics), "queue": _margin(_queue), "queue_empty": _margin(_queue_empty)}
	for tab in Plugins.now_playing_tabs:
		var area := MarginContainer.new()
		(tab["build"] as Callable).call(area)
		_views[str(tab["id"])] = _margin(area)
	for key in _views:
		stage.add_child(_views[key])
		UI.fill(_views[key])
	var header := _shade(true)
	var texts := VBoxContainer.new()
	var room := Control.new()
	texts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	room.custom_minimum_size.x = TAB_SIZE * HEADER_SCALE
	room.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var back := _button(BACK_ICON, Main.close_mini, TAB_SIZE * HEADER_SCALE, 80.0 * HEADER_SCALE)
	back.flat = true
	back.fg_color = ThemeEngine.Colors.Foreground
	var bar := _row(12, [back, texts, room])
	bar.alignment = BoxContainer.ALIGNMENT_BEGIN
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var top_margin := _margin(bar)
	for side in ["left", "right", "top"]:
		top_margin.add_theme_constant_override("margin_" + side, roundi(PADDING * HEADER_SCALE))
	_attach(header, top_margin)
	_title.font_size = roundi(52 * HEADER_SCALE)
	_title.weight = 700
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title.marquee = true
	texts.add_child(_title)
	var progress := NariPanelContainer.new()
	progress.corner_radius = 24.0
	progress.padding = 8
	progress.padding_left = 16
	progress.padding_right = 16
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	progress.add_child(row)
	for node: Control in [_current, _slider, _total]:
		row.add_child(node)
	for label: NariLabel in [_current, _total]:
		label.color = ThemeEngine.Colors.PanelFg
		label.font_size = 31
		label.weight = 700
		label.custom_minimum_size.x = 112
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider.show_buffered = true
	_slider.scale_height = 1.15
	var transport := _row(12, [_shuffle, _button(PREVIOUS_ICON, MediaPlayer.previous, BUTTON_SIZE, 72.0), _play, _button(NEXT_ICON, MediaPlayer.next, BUTTON_SIZE, 72.0), _repeat])
	var volume: NariButton = VOLUME.instantiate()
	volume.flat = false
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tabs := _row(12, [_button(MORE_ICON, _open_options, TAB_SIZE, 44.0), gap, _style(volume, TAB_SIZE, 44.0)])
	_dock.add_theme_constant_override("separation", 16)
	for node: Control in [progress, transport, tabs]:
		_dock.add_child(node)
	_slot.mouse_filter = Control.MOUSE_FILTER_PASS
	_slot.size_flags_vertical = Control.SIZE_SHRINK_END
	_slot.add_child(_dock)
	_attach(_shade(false), _margin(_slot))
	_slot.resized.connect(_place_dock)
	_dock.minimum_size_changed.connect(_place_dock)
	_idle.one_shot = true
	_idle.wait_time = IDLE_TIME
	_idle.timeout.connect(_reveal.bind(false))
	add_child(_idle)
	top.gui_input.connect(_drag_window)
	_slider.drag_started.connect(func(): _seeking = true)
	_slider.drag_ended.connect(func(changed: bool):
		_seeking = false
		if changed:
			MediaPlayer.seek(int(_slider.value)))
	_slider.value_changed.connect(func(value: float):
		if _seeking:
			_current.text = MediaPlayer.format_duration(int(value)))
	_lyrics.line_selected.connect(func(position_ms: int): MediaPlayer.seek(position_ms))
	MediaPlayer.lyrics.lyrics_ready.connect(func(song_id: String, lyrics: Dictionary):
		if song_id == _song_id:
			_lyrics.finish_loading(lyrics))
	MediaPlayer.playback_changed.connect(_update)
	visualizers.shade_changed.connect(_apply_contrast.unbind(1))
	ThemeEngine.follow(overlay, _apply_contrast)
	_update(MediaPlayer.get_playback_state())
	_show("")
	_reveal(true)
	wear(WinampSkin.current())

func _input(event: InputEvent) -> void:
	if _winamp or _wmp or event is InputEventJoypadMotion and absf(event.axis_value) < 0.5:
		return
	if event is InputEventMouseMotion or event is InputEventMouseButton or event is InputEventKey or event is InputEventJoypadButton or event is InputEventScreenTouch:
		_reveal(true)

func _reveal(shown: bool) -> void:
	_idle.stop()
	if shown:
		_idle.start()
	if not shown and (_seeking or not MediaPlayer.is_playing()):
		return
	if shown == overlay.visible and (_fade == null or not _fade.is_running()):
		return
	if _fade:
		_fade.kill()
	overlay.visible = true
	_fade = create_tween()
	_fade.tween_property(overlay, "modulate:a", 1.0 if shown else 0.0, FADE_TIME)
	if not shown:
		_fade.tween_callback(overlay.hide)

func _shade(above: bool) -> Control:
	var holder := Control.new()
	var tint := TextureRect.new()
	var gradient := GradientTexture2D.new()
	var background := ThemeEngine.get_color(ThemeEngine.Colors.Background)
	gradient.gradient = Gradient.new()
	gradient.gradient.colors = PackedColorArray([Color(background, 0.9), Color(background, 0.0)])
	gradient.fill_from = Vector2(0.0, 0.0 if above else 1.0)
	gradient.fill_to = Vector2(0.0, 1.0 if above else 0.0)
	tint.texture = gradient
	tint.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.add_child(tint)
	UI.fill(tint)
	overlay.add_child(holder)
	UI.anchor(holder, 0.0, 0.0 if above else 1.0 - SHADE_BOTTOM, 1.0, SHADE_TOP if above else 1.0)
	return holder

func _attach(holder: Control, content: Control) -> void:
	holder.add_child(content)
	UI.fill(content)

func _margin(content: Control) -> MarginContainer:
	var box := MarginContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_PASS
	for side in ["left", "right", "top", "bottom"]:
		box.add_theme_constant_override("margin_" + side, PADDING)
	box.add_child(content)
	return box

func _button(texture: Texture2D, action: Callable, side: float, glyph: float) -> NariButton:
	var button := NariButton.new()
	button.icon = texture
	button.pressed.connect(action)
	return _style(button, side, glyph)

func _style(button: NariButton, side: float, glyph: float) -> NariButton:
	button.icon_size = Vector2.ONE * glyph
	button.custom_minimum_size = Vector2.ONE * side
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	button.corner_radius = side * 0.21
	button.padding = 9
	button.accent_on_focus = true
	button.focus_mode = Control.FOCUS_ALL
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	return button

func _row(separation: int, nodes: Array) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", separation)
	for node: Control in nodes:
		row.add_child(node)
	return row

func _place_dock() -> void:
	var natural := _dock.get_combined_minimum_size().max(Vector2.ONE)
	var width := minf(_slot.size.x, DOCK_MAX)
	var fit := clampf(width / natural.x, 0.01, 1.0)
	_slot.custom_minimum_size.y = natural.y * fit
	_dock.scale = Vector2.ONE * fit
	_dock.size = Vector2(width / fit, natural.y)
	_dock.position = Vector2((_slot.size.x - width) * 0.5, 0.0)

func _process(delta: float) -> void:
	_elapsed += delta
	if _seeking or _elapsed < 0.05:
		return
	_elapsed = 0.0
	var position := MediaPlayer.get_position()
	_lyrics.set_playback_position(position)
	_slider.set_value_no_signal(position)
	_current.text = MediaPlayer.format_duration(position)

func focus_content() -> void:
	if _winamp or _wmp:
		(_winamp if _winamp else _wmp).focus()
	else:
		_play.grab_focus()

func go_back() -> bool:
	if not _winamp and not _wmp and (not _view.is_empty() or _visualizer >= 0):
		_show("")
		return true
	Main.close_mini()
	return true

func _update(state: Dictionary) -> void:
	var song := MediaPlayer.get_current_song()
	var song_id := str(song.get("id", ""))
	var duration := int(state.get("duration", MediaPlayer.get_duration()))
	var position := int(state.get("position", MediaPlayer.get_position()))
	var live := bool(state.get("live", false))
	var playing := MediaPlayer.is_playing()
	_title.text = str(song.get("title", "Nothing playing"))
	_slider.max_value = maxf(duration, 1.0)
	_slider.editable = not live
	_slider.playing = playing
	_total.text = MediaPlayer.format_duration(duration)
	_total.visible = not live
	if not _seeking:
		_slider.set_value_no_signal(position)
		_current.text = MediaPlayer.format_duration(position)
	if song.is_empty():
		_cover.clear()
	elif Plugins.cover_texture():
		_cover.show_texture(Plugins.cover_texture())
	else:
		_cover.show_cover.callv(MediaPlayer.cover_of(song))
	_play.icon = PAUSE_ICON if playing else PLAY_ICON
	_repeat.icon = REPEAT_ONE_ICON if MediaPlayer.get_repeat() == MediaPlayer.Repeat.ONE else REPEAT_ICON
	_repeat.indicator = MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF
	_shuffle.indicator = MediaPlayer.is_shuffled()
	set_process(playing)
	if not playing:
		_reveal(true)
	if _view == "queue":
		_load_queue()
	if song_id != _song_id:
		_song_id = song_id
		var lyrics: Dictionary = {}
		if not song_id.is_empty():
			lyrics = await MediaPlayer.lyrics.get_lyrics(song_id)
		if song_id != _song_id:
			return
		_lyrics.set_lyrics(lyrics)
		_lyrics.loading = not song_id.is_empty() and MediaPlayer.lyrics.searches_online()
		if not song_id.is_empty():
			MediaPlayer.lyrics.request(song_id)
	_lyrics.set_playback_position(position)

func _load_queue() -> void:
	var queue: Array = await MediaPlayer.get_queue()
	_queue_start = clampi(int(MediaPlayer.get_playback_state().get("index", -1)) + 1, 0, queue.size())
	if _view.begins_with("queue"):
		_view = "queue" if _queue_start < queue.size() else "queue_empty"
		_swap()
	_queue.set_items(range(_queue_start, queue.size()), func(index: int):
		return Items.compact(queue[index], func(): MediaPlayer.skip_to_queue_index(index)), Callable(), true)

func _show(view: String) -> void:
	_view = view
	_visualizer = -1
	visualizers.mode = -1
	if view == "queue":
		_load_queue()
	_swap()

func _show_visualizer(index: int) -> void:
	_view = ""
	_visualizer = index
	visualizers.mode = index
	_swap()

func _swap() -> void:
	for key in _views:
		_views[key].visible = key == _view and _visualizer < 0
	_lyrics.set_playback_position(MediaPlayer.get_position())

func wear(source: String) -> void:
	var nari := NariSkin.is_skin(source)
	var media := nari or WinampSkin.is_media_player(source)
	var skin := WinampSkin.open(source) if not source.is_empty() and not media else null
	var wmp: WmpPlayer = (NariSkinPlayer.new() if nari else WmpPlayer.new()) if media else null
	if wmp and not wmp.open(source) or not source.is_empty() and not media and not skin:
		if wmp:
			wmp.free()
		Dialog.confirm("%s is not a skin Nari can wear" % source.get_file(), "OK", Callable())
		return
	SettingsManager.set_value(WinampPlayer.SECTION, "skin", source)
	if is_node_ready():
		Main.window_refresh_requested.emit()
	for player: Node in [_winamp, _wmp]:
		if player and (wmp or not skin or player == _wmp):
			player.queue_free()
	if wmp or not skin:
		_winamp = null
	_wmp = wmp
	stage.visible = source.is_empty()
	overlay.visible = false
	_idle.stop()
	visualizers.visible = source.is_empty()
	if source.is_empty():
		Main.resize_mini(Vector2i.ZERO)
		Main.resize_mini.call_deferred(Vector2i.ZERO)
		_reveal(true)
		_play.grab_focus.call_deferred()
		return
	if wmp:
		_attach_player(wmp)
		return
	if not _winamp:
		_winamp = WinampPlayer.new()
		_attach_player(_winamp)
	_winamp.skin = skin

func _attach_player(player: Node) -> void:
	player.closed.connect(Main.close_mini)
	player.skin_requested.connect(wear)
	player.files_dropped.connect(Main.open_skins)
	skin_holder.add_child(player)
	player.focus.call_deferred()

func _open_skins() -> void:
	var current := WinampSkin.current()
	var groups := WinampSkin.grouped()
	var options: Array = WinampSkin.KINDS.reduce(func(listed: Array, kind: String): return listed + ([kind] if not groups[kind].is_empty() else []) + groups[kind], [])
	var dialog := Dialog.menu("Skins", "Drop .wsz, .wmz or .nsk files on Nari to add them")
	var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
	list.separation = 0
	list.follow_focus = true
	dialog.content.add_child(list)
	dialog.add_option("Open skins folder", WinampSkin.open_folder, FOLDER_ICON)
	dialog.popup()
	list.set_items(options, func(path: String) -> NariButton:
		if not path in WinampSkin.KINDS:
			return dialog.make_choice(WinampSkin.label(path), path == current, wear.bind(path))
		var header := dialog.make_option(path, Callable(), SKIN_ICON)
		header.disabled = true
		header.focus_mode = Control.FOCUS_NONE
		return header)
	list.custom_minimum_size.y = list.container.cell_height * minf(options.size(), ItemMenu.VISIBLE_OPTIONS)
	list.focus_item(maxi(options.find(current), 1))

func _open_options() -> void:
	var dialog := Dialog.menu("Mini player")
	dialog.add_option("Skins", _open_skins, SKIN_ICON)
	var choices := [["Cover", "", COVER_ICON], ["Lyrics", "lyrics", LYRICS_ICON], ["Queue", "queue", QUEUE_ICON]]
	for tab in Plugins.now_playing_tabs:
		choices.append([str(tab.get("title", tab["id"])), str(tab["id"]), tab["icon"]])
	for choice: Array in choices:
		dialog.content.add_child(dialog.make_choice(choice[0], _visualizer < 0 and _view.trim_suffix("_empty") == choice[1], _show.bind(choice[1]), choice[2]))
	dialog.add_option("Visualizers", func(): Visualizers.open_menu("Visualizers", Visualizers.choices(), _visualizer, _show_visualizer, -1), VISUALIZER_ICON)
	if Main.has_song():
		dialog.add_option("Song options", func(): ItemMenu.now_playing(MediaPlayer.get_current_song()), SONG_ICON)
	dialog.popup()

func _drag_window(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		DisplayServer.window_start_drag(top.get_window().get_window_id())

func _apply_contrast() -> void:
	Visualizers.lift_contrast(overlay, visualizers.tone if top.is_visible_in_tree() else "")
