extends Page

const EMPTY_MESSAGE := preload("res://ui/shared/EmptyMessage.tscn")
const QUEUE_ICON := preload("res://assets/icons/queue_music.svg")
const PLAY_ICON := preload("res://assets/icons/play.svg")
const PAUSE_ICON := preload("res://assets/icons/pause.svg")
const REPEAT_ICON := preload("res://assets/icons/repeat.svg")
const REPEAT_ONE_ICON := preload("res://assets/icons/repeat_one.svg")
const CLEAR_ICON := preload("res://assets/icons/delete.svg")
const RESET_ICON := preload("res://assets/icons/repeat.svg")
const SOUNDBOARD_GRID := preload("res://ui/shared/SoundboardGrid.tscn")
const FADE_TIME := 0.2
const BACKDROP_ALPHA := 0.35
const BACKDROP_SPREAD := 1.5
const SCREEN_TITLES := {"queue": "Queue", "effects": "Effects", "soundboard": "Soundboard"}
const COVER_WIDE := 0.34
const COVER_TALL := 0.46
const COVER_WIDE_TIGHT := 0.86
const COVER_TALL_TIGHT := 0.6
const COVER_MIN := 160.0
const COVER_MAX := 1000.0
const COVER_WIDE_REST := 0.4
const COVER_TALL_REST := 0.56
const COVER_TALL_TIGHT_REST := 0.72
const COVER_MAX_REST := 1080.0
const DOCK_MAX := 1000.0
const SPLIT_GAP := 64.0
const DOCK_HEIGHT_SHARE := 0.5

const QUIET_ACTIONS: Array[StringName] = [&"play_pause", &"previous_track", &"next_track", &"scroll_up", &"scroll_down", &"scroll_left", &"scroll_right"]
@onready var visualizers: Visualizers = %Visualizers
@onready var backdrop: TextureRect = %Backdrop
@onready var layout: MarginContainer = %Layout
@onready var column: VBoxContainer = %Column
@onready var main: Control = %Main
@onready var staged: VBoxContainer = %Staged
@onready var side: VBoxContainer = %Side
@onready var strip: HBoxContainer = %Strip
@onready var dock_slot: Control = %DockSlot
@onready var dock: VBoxContainer = %Dock
@onready var tabs_slot: Control = %TabsSlot
@onready var tabs: NariPanelContainer = %Tabs
@onready var tabs_row: HBoxContainer = %TabsRow
@onready var texts: VBoxContainer = %Texts
@onready var cover_frame: AspectRatioContainer = %CoverFrame
@onready var song_cover: Cover = %Cover
@onready var mini_cover: Cover = %MiniCover
@onready var song_title: NariLabel = %Title
@onready var song_artist: NariLabel = %Artist
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
@onready var stage: VBoxContainer = %Stage
@onready var stage_header: HBoxContainer = %StageHeader
@onready var stage_title: NariLabel = %StageTitle
@onready var stage_action: NariButton = %StageAction
@onready var screens: Control = %Screens
@onready var queue_area: Control = %QueueArea
@onready var queue_list: StairScroll = %Queue
@onready var queue_empty: EmptyMessage = _build_queue_notice()
@onready var lyrics_visualizer: LyricsVisualizer = %LyricsVisualizer
@onready var effects_area: HBoxContainer = %EffectsArea
@onready var effects_pages: PagesContainer = %Pages
@onready var effects_previous: NariButton = %LeftButton
@onready var effects_next: NariButton = %RightButton
@onready var effects_locked: NariLabel = %EffectsLocked
@onready var effects_presets: EffectsPresets = %EffectsPresets
@onready var plugin_effects: EffectsPresets = %PluginEffects
@onready var soundboard_area: SoundboardGrid = _build_soundboard()
@onready var queue_button: NariButton = %Tabs/%QueueButton
@onready var lyrics_button: NariButton = %Tabs/%LyricsButton
@onready var effects_button: NariButton = %Tabs/%EffectsButton
@onready var visualizers_button: NariButton = %Tabs/%VisualizersButton
@onready var soundboard_button: NariButton = %Tabs/%SoundboardButton
@onready var idle_timer: Timer = %IdleTimer
@onready var _screens := {"queue": queue_area, "lyrics": lyrics_visualizer, "effects": effects_area, "soundboard": soundboard_area}

var _plugin_tabs := {}
var _view_buttons := {}
var _queue_version := 0
var _queue_signature := "uninitialized"
var _queue_index := -1
var _queue_start := 0
var _seeking := false
var _elapsed := 0.0
var _lyrics_song_id := ""
var _screen := ""
var _visualizer := -1
var _fade: Tween
var _slide: Tween
var _controls: Tween
var _controls_shown := true
var _controls_amount := 1.0

func _ready() -> void:
	SwipeDismiss.attach(top, [top], func() -> bool: return _screen.is_empty() and _visualizer < 0 and not _seeking)
	_mount_plugin_tabs(_toggle_screen)
	UI.link_current_song(song_title, song_artist)
	for key in _plugin_tabs:
		_screens[key] = _plugin_tabs[key]["area"]
	Plugins.output_changed.connect(_swap_effects)
	_swap_effects()
	ThemeEngine.follow(backdrop, func(): backdrop.self_modulate = ThemeEngine.get_color(ThemeEngine.Colors.BackgroundGradient))
	song_title.marquee = true
	song_artist.marquee = true

	shuffle.pressed.connect(func(): MediaPlayer.shuffle())
	previous.pressed.connect(MediaPlayer.previous)
	pause_play.pressed.connect(MediaPlayer.toggle)
	next.pressed.connect(MediaPlayer.next)
	repeat.pressed.connect(func(): MediaPlayer.repeat())
	more.pressed.connect(func():
		var current := MediaPlayer.get_current_song()
		if not current.is_empty():
			ItemMenu.now_playing(current))
	for screen in ["queue", "lyrics", "effects", "soundboard"]:
		(tabs.get_node("%" + screen.capitalize() + "Button") as NariButton).pressed.connect(_press_tab.bind(screen))
	visualizers_button.pressed.connect(func(): _show_visualizer(_visualizer + 1 if _visualizer + 1 < Visualizers.count() else -1))
	stage_action.pressed.connect(func():
		if _screen == "queue":
			Dialog.confirm("Clear the upcoming songs?", "Clear", MediaPlayer.clear_upcoming, true)
		elif _screen == "effects":
			MediaPlayer.reset_music_distortion())
	queue_list.item_moved.connect(func(from: int, to: int): MediaPlayer.move_in_queue(_queue_start + from, _queue_start + to))
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
	top.resized.connect(_arrange)
	dock.item_rect_changed.connect(_place_backdrop)
	dock_slot.resized.connect(_place_dock)
	if Plugins.effects.is_empty():
		plugin_effects.free()
	UI.pager_arrows(effects_pages, effects_previous, effects_next)
	idle_timer.timeout.connect(func():
		if SettingsManager.theme.now_playing_controls == "auto" and not _seeking:
			_set_controls(false))
	SettingsManager.changed.connect(_on_setting_changed)
	_controls_shown = SettingsManager.theme.now_playing_controls != "hide"
	_controls_amount = 1.0 if _controls_shown else 0.0
	_update(MediaPlayer.get_playback_state())
	_paint_actions()
	_arrange()
	_wake_controls()
	UI.dim_unfocused(_effect_controls())
	pause_play.grab_focus.call_deferred()

func _effect_controls() -> Array:
	var controls: Array = [distorter]
	for presets: Variant in [effects_presets, plugin_effects]:
		if is_instance_valid(presets):
			for row: Node in (presets as EffectsPresets).get_children():
				controls.append_array(row.get_children())
	return controls

func _input(event: InputEvent) -> void:
	if event is InputEventJoypadMotion and absf(event.axis_value) < 0.5:
		return
	for action: StringName in QUIET_ACTIONS:
		if event.is_action(action):
			return
	_wake_controls()

func _on_setting_changed(section: String, key: String, value: Variant) -> void:
	if section != "theme" or key != "now_playing_controls":
		return
	idle_timer.stop()
	if value == "auto":
		_wake_controls()
	else:
		_set_controls(value == "show")

func _wake_controls() -> void:
	if SettingsManager.theme.now_playing_controls != "auto":
		return
	idle_timer.start()
	_set_controls(true)

func _set_controls(shown: bool) -> void:
	if shown == _controls_shown:
		return
	_controls_shown = shown
	if _controls:
		_controls.kill()
	_controls = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT if shown else Tween.EASE_IN)
	_controls.tween_method(_apply_controls, _controls_amount, 1.0 if shown else 0.0, Main.TRANSITION_TIME)
	if shown and not Main.focus_owner():
		pause_play.grab_focus.call_deferred()

func _apply_controls(amount: float) -> void:
	_controls_amount = amount
	for pair in [[tabs_slot, tabs_row], [dock_slot, dock]]:
		var slot: Control = pair[0]
		var content: Control = pair[1]
		content.visible = amount > 0.001
		content.modulate.a = amount
		slot.custom_minimum_size.y = content.get_combined_minimum_size().y * amount * (_dock_scale() if content == dock else 1.0)
	if staged.visible:
		var ratio := _view_ratio()
		var side := lerpf(_cover_side(false), _cover_side(true), amount)
		var width := minf(side * ratio, maxf(_lane(), side))
		cover_frame.ratio = ratio
		cover_frame.custom_minimum_size = Vector2(width, width / ratio)

func _process(delta: float) -> void:
	_elapsed += delta
	if _seeking or _elapsed < 0.05:
		return
	_elapsed = 0.0
	var position := MediaPlayer.get_position()
	lyrics_visualizer.set_playback_position(position)
	song_progress_slider.set_value_no_signal(position)
	song_current_time.text = MediaPlayer.format_duration(position)

func focus_content() -> void:
	pause_play.grab_focus()

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

	for target in [song_cover, mini_cover]:
		if song.is_empty():
			target.clear()
		elif target == song_cover and Plugins.cover_texture():
			target.show_texture(Plugins.cover_texture())
		else:
			var cover := MediaPlayer.cover_of(song)
			target.show_cover(cover[0], cover[1])

	_paint_active(shuffle, MediaPlayer.is_shuffled())
	var playing := MediaPlayer.is_playing()
	set_process(playing)
	song_progress_slider.playing = playing
	_paint_active(repeat, MediaPlayer.get_repeat() != MediaPlayer.Repeat.OFF)
	pause_play.icon = PAUSE_ICON if playing else PLAY_ICON
	repeat.icon = REPEAT_ONE_ICON if MediaPlayer.get_repeat() == MediaPlayer.Repeat.ONE else REPEAT_ICON
	_queue_version = int(state.get("queue_version", 0))
	_queue_index = int(state.get("index", -1))
	if _screen == "queue":
		_load_queue()

func _build_queue_notice() -> EmptyMessage:
	var notice: EmptyMessage = EMPTY_MESSAGE.instantiate()
	notice.show_message([QUEUE_ICON, "Queue empty!", "Songs you add to the queue show up here"])
	notice.hide()
	queue_area.add_child(notice)
	return notice

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
		button.pressed.connect(_press_view.bind(key))

func _build_soundboard() -> SoundboardGrid:
	var grid: SoundboardGrid = SOUNDBOARD_GRID.instantiate()
	grid.interactive = false
	grid.hide()
	screens.add_child(grid)
	UI.fill(grid)
	return grid

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

func go_back() -> bool:
	if _screen.is_empty() and _visualizer < 0:
		return false
	_show_cover()
	return true

func _show_cover() -> void:
	if not _screen.is_empty():
		_toggle_screen(_screen)
	_show_visualizer(-1)

func _press_tab(screen: String) -> void:
	if screen == "lyrics" and _screen == "lyrics" and lyrics_visualizer.recenter():
		return
	_toggle_screen(screen)

func _swap_effects() -> void:
	var shown: Control = _screens["effects"]
	var wanted: Control = effects_locked if Plugins.is_output_connected() else effects_area
	if shown == wanted:
		return
	_screens["effects"] = wanted
	if _screen == "effects":
		shown.hide()
		wanted.show()
		stage_action.visible = wanted == effects_area

func _toggle_screen(screen: String) -> void:
	var leaving: Control = _screens.get(_screen)
	_screen = "" if screen == _screen else screen
	var entering: Control = _screens.get(_screen)
	var relayout := leaving == null or entering == null or _visualizer >= 0
	if entering:
		_visualizer = -1
		visualizers.mode = -1
		_fade_backdrop()
		stage_title.text = SCREEN_TITLES.get(_screen, _plugin_tabs.get(_screen, {}).get("title", ""))
		stage_header.visible = _screen != "lyrics"
		stage_action.visible = _screen == "queue" or (_screen == "effects" and _screens["effects"] == effects_area)
		stage_action.icon = CLEAR_ICON if _screen == "queue" else RESET_ICON
		if _screen == "queue":
			_load_queue()
		elif _screen == "lyrics":
			lyrics_visualizer.set_playback_position(MediaPlayer.get_position())
		if leaving:
			UI.swap(leaving, entering)
		else:
			for panel in _screens.values():
				panel.visible = panel == entering
	_paint_actions()
	if relayout:
		_transition()
	else:
		_enter_screen()

func _enter_screen() -> void:
	if _screen == "queue":
		queue_list.play_entrance()
		queue_list.focus_item(0)

func _show_visualizer(index: int) -> void:
	if index == _visualizer:
		return
	if index >= 0 and not _screen.is_empty():
		_toggle_screen(_screen)
	_set_visualizer(index)

func _set_visualizer(index: int) -> void:
	if index == _visualizer:
		return
	var was_visual := _visualizer >= 0
	_visualizer = index
	visualizers.mode = index
	_paint_actions()
	if was_visual != (index >= 0):
		_transition()
	_fade_backdrop()

func _fade_backdrop() -> void:
	if _fade:
		_fade.kill()
	_fade = create_tween()
	_fade.tween_property(backdrop, "modulate:a", BACKDROP_ALPHA if _visualizer >= 0 else 0.0, FADE_TIME)

func _transition() -> void:
	if _slide:
		_slide.kill()
	var shift := -top.size.y * Main.TRANSITION_SHIFT
	_slide = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC)
	_slide.tween_property(layout, "offset_top", shift, Main.TRANSITION_TIME * 0.5).set_ease(Tween.EASE_IN)
	_slide.tween_property(layout, "offset_bottom", shift, Main.TRANSITION_TIME * 0.5).set_ease(Tween.EASE_IN)
	_slide.tween_property(layout, "modulate:a", 0.0, Main.TRANSITION_TIME * 0.5)
	_slide.chain().tween_callback(func():
		_arrange()
		_enter_screen())
	_slide.chain().tween_property(layout, "offset_top", 0.0, Main.TRANSITION_TIME).set_ease(Tween.EASE_OUT)
	_slide.tween_property(layout, "offset_bottom", 0.0, Main.TRANSITION_TIME).set_ease(Tween.EASE_OUT)
	_slide.tween_property(layout, "modulate:a", 1.0, Main.TRANSITION_TIME)

func _paint_actions() -> void:
	_paint_active(queue_button, _screen == "queue")
	_paint_active(lyrics_button, _screen == "lyrics")
	_paint_active(effects_button, _screen == "effects")
	_paint_active(soundboard_button, _screen == "soundboard")
	_paint_active(visualizers_button, _visualizer >= 0)
	for key in _plugin_tabs:
		_paint_active(_plugin_tabs[key]["button"], _screen == key)
	for key in _view_buttons:
		_view_buttons[key].visible = Plugins.is_cover_view_shown(key)
		_paint_active(_view_buttons[key], Plugins.cover_view == key)

func _press_view(key: String) -> void:
	if Plugins.cover_view != key and not Plugins.is_cover_view_available(key):
		return
	if Plugins.cover_view != key:
		_show_cover()
	Plugins.toggle_cover_view(key)

func _on_cover_view_changed() -> void:
	_paint_actions()
	_layout()
	_update(MediaPlayer.get_playback_state())

func _view_ratio() -> float:
	var view := Plugins.cover_texture()
	return view.get_width() / maxf(view.get_height(), 1.0) if view and view.get_height() > 0 else 1.0

func _paint_active(button: NariButton, active: bool) -> void:
	button.indicator = active

func _arrange() -> void:
	var focused := Main.focus_owner()
	_layout()
	if is_instance_valid(focused) and focused.is_visible_in_tree() and not Main.focus_owner():
		focused.grab_focus()

func _layout() -> void:
	var wide := _wide()
	var panel := not _screen.is_empty()
	var visual := _visualizer >= 0
	var split := wide and panel
	var compact := visual or (panel and not split)
	staged.visible = not compact
	side.visible = panel
	strip.visible = compact
	_move(texts, strip if compact else staged)
	if not compact:
		staged.move_child(texts, cover_frame.get_index() + 1)
	for label in [song_title, song_artist]:
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if compact else HORIZONTAL_ALIGNMENT_CENTER
	_move(dock_slot, staged if split else column)
	if compact:
		_move(tabs_slot, column)
		column.move_child(tabs_slot, dock_slot.get_index() + 1 if dock_slot.get_parent() == column else strip.get_index())
	elif panel:
		_move(tabs_slot, side)
		side.move_child(tabs_slot, side.get_child_count() - 1)
	else:
		_move(tabs_slot, dock)
		dock.move_child(tabs_slot, -1)
	if split:
		UI.anchor(staged, 0.0, 0.0, 0.5, 1.0)
		UI.anchor(side, 0.5, 0.0, 1.0, 1.0)
		staged.offset_right = -SPLIT_GAP * 0.5
		side.offset_left = SPLIT_GAP * 0.5
	else:
		UI.fill(staged)
		UI.fill(side)
	dock_slot.custom_minimum_size.x = minf(DOCK_MAX, _lane())
	strip.custom_minimum_size.x = dock_slot.custom_minimum_size.x
	tabs_slot.custom_minimum_size.x = tabs_row.get_combined_minimum_size().x
	_apply_controls(_controls_amount)
	_place_dock()

func _room() -> Vector2:
	var margins := Vector2(layout.get_theme_constant("margin_left") + layout.get_theme_constant("margin_right"), layout.get_theme_constant("margin_top") + layout.get_theme_constant("margin_bottom"))
	return (top.size - margins).max(Vector2.ONE)

func _wide() -> bool:
	return top.size.x / maxf(top.size.y, 1.0) >= UI.WIDE_RATIO

func _lane() -> float:
	var room := _room()
	return (room.x - SPLIT_GAP) * 0.5 if _wide() and not _screen.is_empty() else room.x

func _cover_side(shown: bool) -> float:
	var reserve := texts.get_combined_minimum_size().y + staged.get_theme_constant("separation") + column.get_theme_constant("separation")
	if shown:
		reserve += dock.get_combined_minimum_size().y * _dock_scale()
	var fit := _room().y - reserve
	var ceiling := COVER_MAX if shown else COVER_MAX_REST
	var side_length: float
	if _wide():
		side_length = minf(top.size.y * (COVER_TALL if shown else COVER_TALL_REST), top.size.x * (COVER_WIDE if shown else COVER_WIDE_REST))
	else:
		side_length = minf(top.size.y * (COVER_TALL_TIGHT if shown else COVER_TALL_TIGHT_REST), top.size.x * COVER_WIDE_TIGHT)
	return clampf(minf(minf(side_length, fit), minf(_lane(), ceiling)), COVER_MIN, ceiling)

func _move(node: Control, parent: Control) -> void:
	if node.get_parent() != parent:
		node.reparent(parent, false)

func _dock_scale() -> float:
	var natural := dock.get_combined_minimum_size().max(Vector2.ONE)
	var width := minf(DOCK_MAX, _lane())
	return clampf(minf(width / natural.x, _room().y * DOCK_HEIGHT_SHARE / natural.y), 0.01, 1.0)

func _place_dock() -> void:
	var dock_scale := _dock_scale()
	dock.scale = Vector2.ONE * dock_scale
	dock.position = Vector2.ZERO
	dock.size = dock_slot.size / dock_scale

func _place_backdrop() -> void:
	var content := Rect2(dock.global_position - top.global_position, dock.size * dock.scale)
	var glow := maxf(content.size.x, content.size.y) * BACKDROP_SPREAD
	backdrop.position = content.get_center() - Vector2.ONE * glow * 0.5
	backdrop.size = Vector2.ONE * glow
