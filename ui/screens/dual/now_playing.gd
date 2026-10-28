extends Page

const EMPTY_MESSAGE := preload("res://ui/shared/EmptyMessage.tscn")
const QUEUE_ICON := preload("res://assets/icons/queue_music.svg")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const REPEAT_ICON := preload("res://assets/icons/repeat.svg")
const REPEAT_ONE_ICON := preload("res://assets/icons/repeat_one.svg")
const CLEAR_ICON := preload("res://assets/icons/delete.svg")
const RESET_ICON := preload("res://assets/icons/repeat.svg")
const COVER_SIZE := Vector2(712, 712)
const LYRICS_COVER_SIZE := Vector2(356, 356)
const STAGE_FADE := 0.25
const AREA_FADE := 0.18
const AREA_SLIDE := 140.0
const SOUNDBOARD_GRID := preload("res://ui/shared/SoundboardGrid.tscn")
const HINT_BUTTON := preload("res://ui/shared/HintButton.tscn")
const TAB_BAR_GAP := 24.0

@onready var top_stage: HBoxContainer = %Stage
@onready var visualizers: Visualizers = %Visualizers
@onready var song_cover: Cover = %Cover
@onready var song_title: NariLabel = %Title
@onready var song_artist: NariLabel = %Artist
@onready var song_details: VBoxContainer = %SongDetails
@onready var lyrics_visualizer: LyricsVisualizer = %LyricsVisualizer
@onready var queue_button: NariButton = %Tabs/%QueueButton
@onready var lyrics_button: NariButton = %Tabs/%LyricsButton
@onready var effects_button: NariButton = %Tabs/%EffectsButton
@onready var soundboard_button: NariButton = %Tabs/%SoundboardButton
@onready var visualizers_button: NariButton = %Tabs/%VisualizersButton
@onready var actions: HBoxContainer = %Actions
@onready var tab_bar: Control = actions.get_parent()
@onready var tabs_row: Control = %Tabs.get_parent()
@onready var device_chip: DeviceChip = _build_device_chip()
@onready var queue_area: MarginContainer = %QueueArea
@onready var queue_list: StairScroll = %Queue
@onready var queue_empty: EmptyMessage = _build_queue_notice()
@onready var soundboard_area: SoundboardGrid = _build_soundboard()
@onready var effects_area: HBoxContainer = %EffectsArea
@onready var effects_locked: NariLabel = %EffectsLocked
@onready var effects_pages: PagesContainer = %Pages
@onready var plugin_effects: EffectsPresets = %PluginEffects
@onready var effects_previous: NariButton = %LeftButton
@onready var effects_next: NariButton = %RightButton
@onready var song_current_time: NariLabel = %CurrentTime
@onready var song_progress_slider: ProgressSlider = %SongProgressSlider
@onready var song_total_time: NariLabel = %TotalTime
@onready var live_chip: Control = %LiveChip
@onready var distorter: SpeedPanel = %Distorter
@onready var shuffle: NariButton = %Shuffle
@onready var previous: NariButton = %Previous
@onready var pause_play: NariButton = %PausePlay
@onready var next: NariButton = %Next
@onready var repeat: NariButton = %Repeat
@onready var more: NariButton = %More
@onready var _areas := {"queue": queue_area, "effects": effects_area, "soundboard": soundboard_area}

var _plugin_tabs := {}
var _view_buttons := {}
var _queue_version := 0
var _queue_signature := "uninitialized"
var _queue_index := -1
var _queue_start := 0
var _seeking := false
var _elapsed := 0.0
var _lyrics_song_id := ""
var _show_lyrics := false
var _area := ""
var _visualizer := -1
var _stage_fade: Tween
var _lyrics_transition: Tween
var _area_transition: Tween

func _ready() -> void:
	SwipeDismiss.attach(top, [top, bottom], func() -> bool: return not _show_lyrics and _visualizer < 0 and not _seeking)
	song_cover.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	UI.link_current_song(song_title, song_artist)

	shuffle.pressed.connect(func(): MediaPlayer.shuffle())
	previous.pressed.connect(MediaPlayer.previous)
	pause_play.pressed.connect(MediaPlayer.toggle)
	next.pressed.connect(MediaPlayer.next)
	repeat.pressed.connect(func(): MediaPlayer.repeat())
	more.pressed.connect(func():
		var current := MediaPlayer.get_current_song()
		if not current.is_empty():
			ItemMenu.now_playing(current))
	for area in _areas:
		(get_node("%Tabs/%" + area.capitalize() + "Button") as NariButton).pressed.connect(_show_area.bind(area))
	_mount_plugin_tabs(_show_area)
	for key in _plugin_tabs:
		_areas[key] = _plugin_tabs[key]["area"]
	Plugins.output_changed.connect(_swap_effects)
	_swap_effects()
	lyrics_button.pressed.connect(func():
		if not (_show_lyrics and lyrics_visualizer.recenter()):
			_toggle_lyrics())
	visualizers_button.pressed.connect(func(): _show_visualizer(_visualizer + 1 if _visualizer + 1 < Visualizers.count() else -1))
	queue_list.item_moved.connect(func(from: int, to: int): MediaPlayer.move_in_queue(_queue_start + from, _queue_start + to))
	song_title.marquee = true
	song_artist.marquee = true
	if Plugins.effects.is_empty():
		plugin_effects.free()
	UI.pager_arrows(effects_pages, effects_previous, effects_next)
	lyrics_visualizer.line_selected.connect(func(position_ms: int): MediaPlayer.seek(position_ms))
	song_progress_slider.drag_started.connect(func(): _seeking = true)
	song_progress_slider.drag_ended.connect(func(changed: bool):
		_seeking = false
		if changed:
			MediaPlayer.seek(int(song_progress_slider.value)))
	song_progress_slider.value_changed.connect(func(value: float):
		if _seeking:
			song_current_time.text = MediaPlayer.format_duration(int(value)))
	MediaPlayer.playback_changed.connect(_update)
	Plugins.cover_view_changed.connect(_on_cover_view_changed)
	MediaPlayer.library_changed.connect(func():
		_lyrics_song_id = ""
		_update(MediaPlayer.get_playback_state()))
	MediaPlayer.lyrics.lyrics_ready.connect(func(song_id: String, lyrics: Dictionary):
		if song_id == _lyrics_song_id:
			lyrics_visualizer.finish_loading(lyrics))
	_update(MediaPlayer.get_playback_state())
	_show_area("queue")
	tab_bar.resized.connect(_fit_tab_bar)
	tabs_row.resized.connect(_fit_tab_bar)
	device_chip.content_changed.connect(_fit_tab_bar)
	InputGlyphs.mode_changed.connect(_fit_tab_bar.unbind(1))
	var effects: Array = []
	for page in effects_pages.get_children():
		if page is EffectsPresets:
			for row: Node in page.get_children():
				effects.append_array(row.get_children())
	UI.dim_unfocused(effects + [distorter])
	pause_play.grab_focus.call_deferred()

func focus_content() -> void:
	pause_play.grab_focus()

func go_back() -> bool:
	if _show_lyrics:
		_toggle_lyrics()
	elif _visualizer >= 0:
		_show_visualizer(-1)
	elif _area != "queue":
		_show_area("queue")
	else:
		return false
	return true

func _refresh_actions() -> void:
	var shown: Array = []
	if _area == "queue":
		shown.append({"text": "Clear", "icon": CLEAR_ICON, "action": func(): Dialog.confirm("Clear the upcoming songs?", "Clear", MediaPlayer.clear_upcoming, true)})
	elif _area == "effects" and _areas["effects"] == effects_area:
		shown.append({"glyph": InputGlyphs.Glyph.X, "text": "Reset", "icon": RESET_ICON, "action": MediaPlayer.reset_music_distortion})
	for child in actions.get_children():
		child.queue_free()
	for action: Dictionary in shown:
		var button: HintButton = HINT_BUTTON.instantiate()
		button.solid = true
		button.fg_color = ThemeEngine.Colors.PanelFg
		actions.add_child(button)
		button.hint = action
	Main.set_shortcuts(shown)
	_fit_tab_bar()

func _build_device_chip() -> DeviceChip:
	var chip := DeviceChip.new()
	chip.flat = true
	chip.font_weight = 700
	chip.font_size = 40
	chip.icon_size = Vector2.ONE * 52
	chip.separation = 12
	chip.padding_left = 12
	chip.padding_right = 12
	chip.fg_color = ThemeEngine.Colors.Foreground
	chip.custom_minimum_size.y = 66
	chip.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tab_bar.add_child(chip)
	return chip

func _fit_tab_bar() -> void:
	if not is_node_ready():
		return
	var room := (tab_bar.size.x - tabs_row.get_combined_minimum_size().x) * 0.5 - TAB_BAR_GAP
	device_chip.compact = device_chip.natural_width() > room
	var buttons: Array = actions.get_children().filter(func(child: Node) -> bool: return child is HintChip and not child.is_queued_for_deletion())
	var width := actions.get_theme_constant("separation") * maxf(buttons.size() - 1, 0.0)
	for button: HintChip in buttons:
		width += button.natural_width()
	for button: HintChip in buttons:
		button.compact = width > room

func _paint_tabs() -> void:
	_paint_tab(queue_button, _area == "queue")
	_paint_tab(effects_button, _area == "effects")
	_paint_tab(soundboard_button, _area == "soundboard")
	_paint_tab(lyrics_button, _show_lyrics)
	_paint_tab(visualizers_button, _visualizer >= 0)
	for key in _plugin_tabs:
		_paint_tab(_plugin_tabs[key]["button"], _area == key)
	for key in _view_buttons:
		_view_buttons[key].visible = Plugins.is_cover_view_shown(key)
		_paint_tab(_view_buttons[key], Plugins.cover_view == key)

func _paint_tab(button: NariButton, active: bool) -> void:
	button.indicator = active

func _swap_effects() -> void:
	var shown: Control = _areas["effects"]
	var wanted: Control = effects_locked if Plugins.is_output_connected() else effects_area
	if shown == wanted:
		return
	_areas["effects"] = wanted
	if _area == "effects":
		shown.hide()
		wanted.modulate.a = 1.0
		wanted.show()
		_refresh_actions()

func _show_area(area: String) -> void:
	if area == _area:
		return
	var leaving: Control = _areas.get(_area)
	var entering: Control = _areas.get(area)
	_area = area
	if area == "queue":
		_load_queue()
	if _area_transition and _area_transition.is_valid():
		_area_transition.kill()
	_area_transition = create_tween().set_parallel(true)
	if leaving:
		_area_transition.tween_property(leaving, "modulate:a", 0.0, AREA_FADE)
		_area_transition.tween_property(leaving, "position:y", AREA_SLIDE, AREA_FADE).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		_area_transition.chain().tween_callback(func():
			leaving.hide()
			leaving.position.y = 0.0)
	if entering:
		for panel in _areas.values():
			if panel != entering and panel != leaving:
				panel.hide()
		entering.modulate.a = 0.0
		entering.position.y = -AREA_SLIDE
		entering.show()
		var arrive := _area_transition.chain() if leaving else _area_transition
		arrive.tween_property(entering, "modulate:a", 1.0, AREA_FADE)
		arrive.parallel().tween_property(entering, "position:y", 0.0, AREA_FADE).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_paint_tabs()
	_refresh_actions()
	if area == "queue":
		queue_list.play_entrance()
		var from_tab := Main.focus_owner() == queue_button
		await get_tree().process_frame
		if is_instance_valid(queue_list) and from_tab:
			queue_list.focus_item(0)

func _process(delta: float) -> void:
	_elapsed += delta
	if _seeking or _elapsed < 0.05:
		return
	_elapsed = 0.0
	var position := MediaPlayer.get_position()
	lyrics_visualizer.set_playback_position(position)
	song_progress_slider.set_value_no_signal(position)
	song_current_time.text = MediaPlayer.format_duration(position)

func _update(state: Dictionary) -> void:
	var song := MediaPlayer.get_current_song()
	var duration := int(state.get("duration", MediaPlayer.get_duration()))
	var position := int(state.get("position", MediaPlayer.get_position()))
	var song_id := str(song.get("id", ""))
	if song_id != _lyrics_song_id:
		_lyrics_song_id = song_id
		var current_lyrics: Dictionary = {}
		if not song_id.is_empty():
			current_lyrics = await MediaPlayer.lyrics.get_lyrics(song_id)
		if song_id != _lyrics_song_id:
			return
		lyrics_visualizer.set_lyrics(current_lyrics)
		lyrics_visualizer.loading = not song_id.is_empty() and MediaPlayer.lyrics.searches_online()
		if not song_id.is_empty():
			MediaPlayer.lyrics.request(song_id)
	lyrics_visualizer.set_playback_position(position)
	song_title.text = str(song.get("title", "Nothing playing"))
	song_artist.text = str(song.get("artist", ""))
	song_progress_slider.max_value = maxf(duration, 1.0)
	song_total_time.text = MediaPlayer.format_duration(duration)
	var live := bool(state.get("live", false))
	live_chip.visible = live
	distorter.locked = live
	song_progress_slider.editable = not live
	song_total_time.visible = not live
	if not _seeking:
		song_progress_slider.set_value_no_signal(position)
		song_current_time.text = MediaPlayer.format_duration(position)

	if song.is_empty():
		song_cover.clear()
	elif Plugins.cover_texture():
		song_cover.show_texture(Plugins.cover_texture())
	else:
		var cover := MediaPlayer.cover_of(song)
		song_cover.show_cover(cover[0], cover[1])

	shuffle.indicator = MediaPlayer.is_shuffled()
	var playing := MediaPlayer.is_playing()
	set_process(playing)
	song_progress_slider.playing = playing
	repeat.indicator = MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF
	pause_play.icon = PAUSE_ICON if playing else PLAY_ICON
	repeat.icon = REPEAT_ONE_ICON if MediaPlayer.get_repeat() == MediaPlayer.Repeat.ONE else REPEAT_ICON
	_queue_version = int(state.get("queue_version", 0))
	_queue_index = int(state.get("index", -1))
	if _area == "queue":
		_load_queue()

func _build_queue_notice() -> EmptyMessage:
	var notice: EmptyMessage = EMPTY_MESSAGE.instantiate()
	notice.show_message([QUEUE_ICON, "Queue empty!", "Songs you add to the queue show up here"])
	notice.hide()
	queue_area.add_child(notice)
	return notice

func _load_queue() -> void:
	var signature := "%d:%d" % [_queue_version, _queue_index]
	if signature == _queue_signature:
		return
	_queue_signature = signature
	var queue: Array = await MediaPlayer.get_queue()
	var start := clampi(_queue_index + 1, 0, queue.size())
	_queue_start = start
	queue_empty.visible = start >= queue.size()
	queue_list.visible = not queue_empty.visible
	queue_list.set_items(range(start, queue.size()), func(index: int):
		var row := Items.song(queue[index], func(): MediaPlayer.skip_to_queue_index(index))
		row.removable = true
		row.remove_requested.connect(MediaPlayer.remove_from_queue.bind(index))
		queue_list.add_drag_handle(row.get_node("%Cover"), row)
		return row, Callable(), true)

func _show_visualizer(index: int) -> void:
	if index == _visualizer:
		return
	var was_visual := _visualizer >= 0
	_visualizer = index
	visualizers.mode = index
	if was_visual != (index >= 0):
		_fade_stage(index < 0)
	_paint_tabs()

func _fade_stage(shown: bool) -> void:
	if _stage_fade:
		_stage_fade.kill()
	_stage_fade = create_tween()
	if shown:
		top_stage.show()
	_stage_fade.tween_property(top_stage, "modulate:a", 1.0 if shown else 0.0, STAGE_FADE)
	if not shown:
		_stage_fade.tween_callback(top_stage.hide)

func _mount_plugin_tabs(toggle: Callable) -> void:
	for tab in Plugins.now_playing_tabs:
		var key := str(tab["id"])
		var button: NariButton = soundboard_button.duplicate(Node.DUPLICATE_SCRIPTS)
		button.icon = tab["icon"]
		soundboard_button.add_sibling(button)
		var area := MarginContainer.new()
		area.hide()
		soundboard_area.add_sibling(area)
		UI.fill(area)
		(tab["build"] as Callable).call(area)
		_plugin_tabs[key] = {"button": button, "area": area, "title": str(tab.get("title", ""))}
		button.pressed.connect(toggle.bind(key))
	for view in Plugins.cover_views:
		var key := str(view["id"])
		var button: NariButton = soundboard_button.duplicate(Node.DUPLICATE_SCRIPTS)
		button.icon = view["icon"]
		soundboard_button.add_sibling(button)
		_view_buttons[key] = button
		button.pressed.connect(Plugins.toggle_cover_view.bind(key))

func _on_cover_view_changed() -> void:
	if _lyrics_transition and _lyrics_transition.is_valid():
		_lyrics_transition.kill()
	song_cover.custom_minimum_size = _cover_size()
	_paint_tabs()
	_fit_tab_bar()
	_update(MediaPlayer.get_playback_state())

func _cover_size() -> Vector2:
	var base := LYRICS_COVER_SIZE if _show_lyrics else COVER_SIZE
	var view := Plugins.cover_texture()
	if not view or view.get_width() <= 0:
		return base
	return Vector2(base.x, base.x * view.get_height() / float(view.get_width()))

func _build_soundboard() -> SoundboardGrid:
	var grid: SoundboardGrid = SOUNDBOARD_GRID.instantiate()
	grid.interactive = false
	queue_area.get_parent().add_child(grid)
	UI.fill(grid)
	grid.hide()
	return grid

func _toggle_lyrics() -> void:
	_show_lyrics = not _show_lyrics
	song_details.visible = not _show_lyrics
	lyrics_visualizer.visible = _show_lyrics
	if _lyrics_transition and _lyrics_transition.is_valid():
		_lyrics_transition.kill()
	lyrics_visualizer.modulate.a = 0.0 if _show_lyrics else 1.0
	song_details.modulate.a = 0.0 if not _show_lyrics else 1.0
	_lyrics_transition = create_tween().set_parallel(true)
	_lyrics_transition.tween_property(song_cover, "custom_minimum_size", _cover_size(), 0.55).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	if _show_lyrics:
		_lyrics_transition.tween_property(lyrics_visualizer, "modulate:a", 1.0, 0.35).set_delay(0.08).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	else:
		_lyrics_transition.tween_property(song_details, "modulate:a", 1.0, 0.35).set_delay(0.08).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_paint_tabs()
	if _show_lyrics:
		lyrics_visualizer.set_playback_position(MediaPlayer.get_position())
