extends Node

const NAVIGATION := ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_focus_next", "ui_focus_prev"]
const SWAP_FADE := 0.25
const SWAP_SETTLE := 0.05
const BACK_DEBOUNCE_MS := 300
const IDLE_DELAY_MS := 30000
const TRAY_FPS := 10
const FALLBACK_FPS := 60
const SAVING_FACTORS := {"light": 0.75, "medium": 0.5, "strong": 0.25}
const PC_SCALE_HEIGHT := 2160.0
const MIN_UI_SIZE := 720.0
const MOBILE_ASPECT := 4.0 / 3.0
const STICK_PRESS := 0.5
const STICK_RELEASE := 0.3
const REPEAT_DELAY := 0.4
const REPEAT_RATE := 0.08
const STICK_DPAD := {JOY_AXIS_LEFT_X: [JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT], JOY_AXIS_LEFT_Y: [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN]}
const STICK_SCROLL_SPEED := 2400.0
const BOTTOM_NAME := "BottomWindow"
const BOTTOM_SIZE := Vector2(1240.0, 1080.0)
const BOTTOM_MIN_SIZE := Vector2i(360, 320)
const BOTTOM_GAP := 16
const THEME_OVERLAYS := preload("res://ui/shared/ThemeOverlays.tscn")
const DPAD := [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]
const WINDOW_MODES := {"windowed": Window.MODE_WINDOWED, "fullscreen": Window.MODE_FULLSCREEN, "exclusive": Window.MODE_EXCLUSIVE_FULLSCREEN}
const RESIZE_MARGIN := 8.0
const RESIZE_EDGES := {
	Vector2i(-1, -1): [DisplayServer.WINDOW_EDGE_TOP_LEFT, Input.CURSOR_FDIAGSIZE], Vector2i(0, -1): [DisplayServer.WINDOW_EDGE_TOP, Input.CURSOR_VSIZE],
	Vector2i(1, -1): [DisplayServer.WINDOW_EDGE_TOP_RIGHT, Input.CURSOR_BDIAGSIZE], Vector2i(-1, 0): [DisplayServer.WINDOW_EDGE_LEFT, Input.CURSOR_HSIZE],
	Vector2i(1, 0): [DisplayServer.WINDOW_EDGE_RIGHT, Input.CURSOR_HSIZE], Vector2i(-1, 1): [DisplayServer.WINDOW_EDGE_BOTTOM_LEFT, Input.CURSOR_BDIAGSIZE],
	Vector2i(0, 1): [DisplayServer.WINDOW_EDGE_BOTTOM, Input.CURSOR_VSIZE], Vector2i(1, 1): [DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT, Input.CURSOR_FDIAGSIZE],
}

@onready var top_view: Node = get_node_or_null("%TopView")
@onready var bottom_view: Node = get_node_or_null(BOTTOM_NAME) if has_node(BOTTOM_NAME) else get_node_or_null("%BottomView")
@onready var screens: Node = $DSManager

var _last_back_msec := -BACK_DEBOUNCE_MS
var _last_back_handled := false
var _last_input_msec := 0
var _restore_mode := Window.MODE_WINDOWED
var _in_tray := false
var _physics_ticks := 60
var _focused := true
var _stick := {}
var _held: InputEventJoypadButton
var _repeat_in := 0.0
var _scroll_targets: Array = []
var _resize_cursor := Input.CURSOR_ARROW

func _ready() -> void:
	if _forward_links():
		return
	get_tree().quit_on_go_back = false
	if OS.has_feature("pc"):
		get_tree().auto_accept_quit = false
	if Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").connect("tray_command", _on_tray_command)
	Engine.max_fps = SettingsManager.performance.max_fps
	_mount_theme_overlays()
	InputGlyphs.swap_face = SettingsManager.general.swap_face_glyphs
	InputGlyphs.swap_actions = SettingsManager.general.nintendo_layout
	var idle_check := Timer.new()
	add_child(idle_check)
	idle_check.timeout.connect(_update_idle_fps)
	idle_check.start(1.0)
	if screens.ayn_thor_plugin:
		screens.ayn_thor_plugin.connect("second_screen_input", func(_action, _x, _y, _pid):
			InputGlyphs.set_gamepad(false)
			_wake())
	SettingsManager.changed.connect(func(section: String, key: String, value: Variant):
		if section == "performance" and key == "max_fps":
			Engine.max_fps = int(value)
		elif section == "general" and key == "dual_screen":
			if screens.ayn_thor_plugin and value:
				screens.ayn_thor_plugin.init_screen()
			elif screens.ayn_thor_plugin:
				screens.ayn_thor_plugin.destroy_screen()
			_update_layout()
		elif section == "general" and key == "swap_screens":
			_swap_screens()
		elif section == "theme" and key == "ui_scale":
			_follow_orientation()
		elif section == "general" and key in ["window_mode", "resolution", "window_borders"]:
			_apply_window_mode()
		elif section == "general" and key == "swap_face_glyphs":
			InputGlyphs.swap_face = bool(value)
		elif section == "general" and key == "nintendo_layout":
			InputGlyphs.swap_actions = bool(value)
		elif section == "general" and key in ["avoid_notch", "avoid_system_bars"]:
			_update_insets()
		elif section == "theme" and key == "reduce_motion":
			_refresh_motion()
		elif section == "performance" and key == "battery_saving" or section == "playback" and key == "keep_screen_on":
			_update_idle_fps())
	screens.second_screen_availability_changed.connect(_update_layout.unbind(1))
	get_window().size_changed.connect(_follow_orientation)
	_apply_window_mode()
	_follow_orientation()
	_refresh_motion()
	ThemeEngine.apply_theme()
	Themes.wait_for_media()
	Main.register_screens(top_view if top_view else self, bottom_view, %TopScreenContainer, get_node_or_null("%BottomScreenContainer"))
	if screens.ayn_thor_plugin and not SettingsManager.general.dual_screen:
		screens.ayn_thor_plugin.destroy_screen()
	_update_layout()
	if not Main.setup_done:
		Main.change_page(Main.Pages.Welcome, {}, false)
	elif Main.loading_held:
		Main.change_page(Main.Pages.Welcome, {"step": 4}, false)
	else:
		Main.go_startup()
	Main.preload_pages()

func _process(delta: float) -> void:
	_repeat_held(delta)
	_scroll_stick()
	if not Main.reduce_motion:
		return
	for tween in get_tree().get_processed_tweens():
		if tween.get_loops_left() != -1 and tween.is_running():
			tween.custom_step(3600.0)

func _follow_orientation() -> void:
	var window := get_window()
	var base := Vector2(ProjectSettings.get_setting("display/window/size/viewport_width"), ProjectSettings.get_setting("display/window/size/viewport_height"))
	var window_size := Vector2(window.size).max(Vector2.ONE)
	var scale := 1.0
	if OS.has_feature("pc"):
		var resolution := _exclusive_resolution()
		window.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT if resolution else Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
		var screen_height := float(resolution.y) if resolution else float(DisplayServer.screen_get_size(window.current_screen).y)
		if resolution:
			window_size = Vector2(resolution)
		window.content_scale_size = Vector2i(window_size)
		scale = maxf(screen_height, PC_SCALE_HEIGHT * 0.5) / PC_SCALE_HEIGHT
	else:
		var short := minf(base.x, base.y)
		var mobile := Vector2i(roundi(short * MOBILE_ASPECT), roundi(short))
		window.content_scale_size = Vector2i(mobile.y, mobile.x) if window.size.y > window.size.x else mobile
	var stretch := minf(window_size.x / window.content_scale_size.x, window_size.y / window.content_scale_size.y)
	var largest := minf(window_size.x, window_size.y) / (MIN_UI_SIZE * stretch)
	window.content_scale_factor = minf(scale * SettingsManager.theme.ui_scale, largest)
	_fit_bottom_window()
	screens.fit_main_screen()
	_update_insets()

func _apply_window_mode() -> void:
	if not OS.has_feature("pc"):
		return
	var window := get_window()
	var mode: int = WINDOW_MODES.get(SettingsManager.general.window_mode, Window.MODE_WINDOWED)
	window.borderless = mode == Window.MODE_WINDOWED and not SettingsManager.general.window_borders
	if window.mode != mode and window.mode != Window.MODE_MINIMIZED and not (mode == Window.MODE_WINDOWED and window.mode == Window.MODE_MAXIMIZED):
		window.mode = mode
	_follow_orientation()

func _resize_window(event: InputEventMouse) -> bool:
	var window := get_window()
	var edge: Array = []
	if window.borderless and window.mode == Window.MODE_WINDOWED:
		var area := get_viewport().get_visible_rect().size
		var margin := RESIZE_MARGIN * area.x / maxf(window.size.x, 1.0)
		var side := Vector2i(_edge_side(event.position.x, area.x, margin), _edge_side(event.position.y, area.y, margin))
		edge = RESIZE_EDGES.get(side, [])
	var cursor: Input.CursorShape = edge[1] if not edge.is_empty() else Input.CURSOR_ARROW
	if cursor != _resize_cursor:
		_resize_cursor = cursor
		Input.set_default_cursor_shape(cursor)
	if edge.is_empty() or not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return false
	DisplayServer.window_start_resize(edge[0], window.get_window_id())
	return true

func _exclusive_resolution() -> Vector2i:
	if SettingsManager.general.window_mode != "exclusive" or SettingsManager.general.resolution.is_empty():
		return Vector2i.ZERO
	var parts := SettingsManager.general.resolution.split("x")
	return Vector2i(int(parts[0]), int(parts[1])) if parts.size() == 2 else Vector2i.ZERO

func _update_insets() -> void:
	if not OS.has_feature("mobile"):
		return
	var window := get_window()
	var canvas_scale := get_viewport().get_visible_rect().size.y / maxf(window.size.y, 1.0)
	var insets := Vector4.ZERO
	var sources: Array = []
	if screens.ayn_thor_plugin:
		if SettingsManager.general.avoid_system_bars:
			sources.append(screens.ayn_thor_plugin.system_bar_insets())
		if SettingsManager.general.avoid_notch:
			sources.append(screens.ayn_thor_plugin.display_cutout_insets())
	elif SettingsManager.general.avoid_notch:
		var bounds := Rect2(window.position, window.size)
		var safe := Rect2(DisplayServer.get_display_safe_area())
		sources.append([maxf(safe.position.x - bounds.position.x, 0.0), maxf(safe.position.y - bounds.position.y, 0.0),
			maxf(bounds.end.x - safe.end.x, 0.0), maxf(bounds.end.y - safe.end.y, 0.0)])
	for source: Variant in sources:
		for side in mini(source.size(), 4):
			insets[side] = maxf(insets[side], float(source[side]))
	Main.set_insets(insets * canvas_scale)

func _refresh_motion() -> void:
	match SettingsManager.theme.reduce_motion:
		"always":
			Main.reduce_motion = true
		"never":
			Main.reduce_motion = false
		_:
			Main.reduce_motion = Engine.has_singleton("MusicService") and Engine.get_singleton("MusicService").isReduceMotionEnabled()

func _update_layout() -> void:
	var dual: bool = bottom_view != null and SettingsManager.general.dual_screen and (screens.has_second_screen or not screens.ayn_thor_plugin)
	if screens.is_swapped != (dual and SettingsManager.general.swap_screens and not bottom_view is Window):
		screens.swap_screens()
	Main.set_dual(dual)
	if bottom_view is Window:
		_show_bottom_window(dual)
	elif bottom_view is SubViewport and not screens.ayn_thor_plugin:
		bottom_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if dual else SubViewport.UPDATE_DISABLED

func _wake() -> void:
	_last_input_msec = Time.get_ticks_msec()
	if not _in_tray and Engine.max_fps != SettingsManager.performance.max_fps:
		Engine.max_fps = SettingsManager.performance.max_fps

func _update_idle_fps() -> void:
	var fps: int = SettingsManager.performance.max_fps
	var busy: bool = MediaPlayer.library_loading or Main.current_page == Main.Pages.Soundboard \
		or (Main.current_page == Main.Pages.NowPlaying and MediaPlayer.is_playing()) \
		or get_tree().get_processed_tweens().any(func(tween: Tween): return tween.get_loops_left() != -1)
	if _in_tray:
		fps = TRAY_FPS
	elif not _focused or not busy and Time.get_ticks_msec() - _last_input_msec >= IDLE_DELAY_MS:
		var rate := DisplayServer.screen_get_refresh_rate()
		var full := fps
		if full <= 0:
			full = roundi(rate) if rate > 0.0 else FALLBACK_FPS
		fps = maxi(roundi(full * SAVING_FACTORS.get(SettingsManager.performance.battery_saving, 1.0)), 1)
	if Engine.max_fps != fps:
		Engine.max_fps = fps
	var keep_on: bool = SettingsManager.playback.keep_screen_on and _focused and not _in_tray and MediaPlayer.is_playing()
	if DisplayServer.screen_is_kept_on() != keep_on:
		DisplayServer.screen_set_keep_on(keep_on)

func _swap_screens() -> void:
	if not Main.dual:
		return
	var veils: Array[ColorRect] = []
	for view in [top_view, bottom_view]:
		var layer := CanvasLayer.new()
		layer.layer = 100
		var veil := ColorRect.new()
		veil.color = ThemeEngine.get_color(ThemeEngine.Colors.Background)
		veil.modulate.a = 0.0
		layer.add_child(veil)
		view.add_child(layer)
		veil.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		veils.append(veil)
	var fade := func(alpha: float):
		for veil in veils:
			veil.modulate.a = alpha
	var tween := create_tween()
	tween.tween_method(fade, 0.0, 1.0, SWAP_FADE)
	tween.tween_callback(_update_layout)
	tween.tween_interval(SWAP_SETTLE)
	tween.tween_method(fade, 1.0, 0.0, SWAP_FADE)
	tween.tween_callback(func():
		for veil in veils:
			veil.get_parent().queue_free())

func _input(event: InputEvent) -> void:
	InputGlyphs.observe(event)
	_wake()
	if event is InputEventMouse and OS.has_feature("pc") and _resize_window(event):
		get_viewport().set_input_as_handled()
		return
	if event is InputEventJoypadMotion and STICK_DPAD.has(event.axis):
		get_viewport().set_input_as_handled()
		_steer(event)
		return
	if event is InputEventJoypadButton and event.button_index in DPAD and not event.has_meta(&"repeat"):
		_track_held(event)
	if DevTools.handle_key(event):
		get_viewport().set_input_as_handled()
		return
	if DevTools.console_open() and not (event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag):
		return
	if InputMap.has_action("back") and event.is_action_pressed("back") and _go_back():
		get_viewport().set_input_as_handled()
		return
	if _browse(event):
		get_viewport().set_input_as_handled()
		return
	if _trigger_shortcut(event):
		get_viewport().set_input_as_handled()
		return
	_forward_input(event)

static func _edge_side(coordinate: float, length: float, margin: float) -> int:
	if coordinate < margin:
		return -1
	if coordinate > length - margin:
		return 1
	return 0

func _browse(event: InputEvent) -> bool:
	var step := 0
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_XBUTTON1:
				step = -1
			MOUSE_BUTTON_XBUTTON2:
				step = 1
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_FORWARD or event.alt_pressed and event.keycode == KEY_RIGHT:
			step = 1
		elif event.alt_pressed and event.keycode == KEY_LEFT:
			step = -1
	if step < 0:
		_go_back()
	elif step > 0:
		Main.go_forward()
	return step != 0

func _steer(event: InputEventJoypadMotion) -> void:
	var key := Vector2i(event.device, event.axis)
	var current: int = _stick.get(key, -1)
	var threshold := STICK_RELEASE if current != -1 else STICK_PRESS
	var button := -1
	if absf(event.axis_value) >= threshold:
		button = STICK_DPAD[event.axis][1 if event.axis_value > 0.0 else 0]
	if button == current:
		return
	_stick[key] = button
	if current != -1:
		_push_dpad.call_deferred(event.device, current, false, false, true)
	if button != -1:
		_push_dpad.call_deferred(event.device, button, true, false, true)

func _push_dpad(device: int, button: int, pressed: bool, repeat := false, stick := false) -> void:
	var event := InputEventJoypadButton.new()
	event.device = device
	event.button_index = button as JoyButton
	event.pressed = pressed
	if repeat:
		event.set_meta(&"repeat", true)
	if stick:
		event.set_meta(&"stick", true)
	get_viewport().push_input(event)

func _track_held(event: InputEventJoypadButton) -> void:
	if event.pressed:
		_held = event
		_repeat_in = REPEAT_DELAY
	elif _held and _held.device == event.device and _held.button_index == event.button_index:
		_held = null

func _repeat_held(delta: float) -> void:
	if not _held:
		return
	_repeat_in -= delta
	if _repeat_in <= 0.0:
		_repeat_in = REPEAT_RATE
		_push_dpad(_held.device, _held.button_index, true, true, _held.has_meta(&"stick"))

func _scroll_stick() -> void:
	var stick := Input.get_vector("scroll_left", "scroll_right", "scroll_up", "scroll_down")
	if stick == Vector2.ZERO or get_tree().get_nodes_in_group(LyricsVisualizer.STICK_GROUP).any(func(node: CanvasItem): return node.is_visible_in_tree()):
		_scroll_targets = []
		return
	if _scroll_targets.is_empty():
		_scroll_targets = [_scroll_target(true), _scroll_target(false)]
	for axis in 2:
		var container: SmoothScrollContainer = _scroll_targets[axis]
		var amount := stick.y if axis == 0 else stick.x
		if amount == 0.0 or not is_instance_valid(container) or not container.is_visible_in_tree():
			continue
		container.last_scroll_type = SmoothScrollContainer.SCROLL_TYPE.WHEEL
		container.scroll_damper = container.wheel_scroll_damper
		container.scrollbar_animator.kill_scroll_tweens()
		if axis == 0:
			container.velocity.y = -amount * STICK_SCROLL_SPEED
		else:
			container.velocity.x = -amount * STICK_SCROLL_SPEED
		container.set_process(true)

func _scroll_target(vertical: bool) -> SmoothScrollContainer:
	var node: Node = Main.focus_owner()
	while node:
		if node is SmoothScrollContainer and (node.should_scroll_vertical() if vertical else node.should_scroll_horizontal()):
			return node
		node = node.get_parent()
	var best: SmoothScrollContainer = null
	for found: SmoothScrollContainer in Main.input_root().find_children("*", "SmoothScrollContainer", true, false):
		if found.is_visible_in_tree() and (found.should_scroll_vertical() if vertical else found.should_scroll_horizontal()) and (not best or found.size.x * found.size.y > best.size.x * best.size.y):
			best = found
	return best

func _trigger_shortcut(event: InputEvent) -> bool:
	if event.is_action_pressed("play_pause") and Main.has_song():
		MediaPlayer.toggle()
		return true
	if Main.has_dialog():
		return false
	if event.is_action_pressed("previous_track") and Main.has_song():
		MediaPlayer.previous()
		return true
	if event.is_action_pressed("next_track") and Main.has_song():
		MediaPlayer.next()
		return true
	if event.is_action_pressed("now_playing") and not Main.loading_held and Main.current_page != Main.Pages.Welcome:
		var pill: NowPlayingPill = _pill()
		if pill and pill.variant == "comfy" and InputGlyphs.navigating():
			pill.focus_pill()
		elif Main.current_page != Main.Pages.NowPlaying and Main.has_song():
			Main.open_now_playing()
		elif Main.current_page == Main.Pages.NowPlaying:
			for chip: DeviceChip in get_tree().get_nodes_in_group(DeviceChip.GROUP):
				if chip.is_visible_in_tree():
					chip.open_picker()
					break
		return true
	return Main.trigger_shortcut(event)

func _pill() -> NowPlayingPill:
	for pill: NowPlayingPill in get_tree().get_nodes_in_group(NowPlayingPill.GROUP):
		if pill.is_visible_in_tree():
			return pill
	return null

func _forward_input(event: InputEvent) -> void:
	if not (event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		return
	var view := Main.input_view()
	if event.is_pressed() and not Main.focus_owner():
		for action in NAVIGATION:
			if event.is_action(action):
				get_viewport().set_input_as_handled()
				Main.focus_content()
				return
	if view is Viewport and view != get_viewport():
		get_viewport().set_input_as_handled()
		view.push_input(event, false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_SCENE_INSTANTIATED and _single_screen():
		_flatten_screens()
	elif what == NOTIFICATION_WM_GO_BACK_REQUEST:
		if DevTools.console_open():
			DevTools.toggle_console()
		elif not _go_back():
			if Engine.has_singleton("AndroidRuntime"):
				Engine.get_singleton("AndroidRuntime").getActivity().moveTaskToBack(true)
			else:
				_quit()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_focused = true
		_refresh_motion()
		if get_window().mode != Window.MODE_MINIMIZED:
			_leave_tray()
		_wake()
	elif what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_focused = false
		_held = null
		_update_idle_fps()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if OS.has_feature("pc") and SettingsManager.general.close_to_tray:
			_set_window_visible(false)
		else:
			_quit()

func _mount_theme_overlays() -> void:
	if top_view:
		$ThemeOverlays.reparent(top_view, false)
	if bottom_view:
		bottom_view.add_child(THEME_OVERLAYS.instantiate())

func _single_screen() -> bool:
	return OS.has_feature("pc") or not Main.has_second_screen()

func _flatten_screens() -> void:
	$DSManager.main_screen = null
	$DSManager.second_screen = null
	for child in $TopScreen/TopView.get_children():
		child.owner = null
		child.reparent(self, false)
		child.owner = self
	if OS.has_feature("pc"):
		_detach_bottom_screen()
	$TopScreen.free()
	$BottomScreen.free()

func _detach_bottom_screen() -> void:
	var window := Window.new()
	window.name = BOTTOM_NAME
	window.title = "%s · Bottom screen" % ProjectSettings.get_setting("application/config/name", "Nari")
	window.visible = false
	window.force_native = true
	window.gui_embed_subwindows = true
	window.min_size = BOTTOM_MIN_SIZE
	window.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	window.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	add_child(window)
	window.owner = self
	for child in $BottomScreen/BottomView.get_children():
		child.owner = null
		child.reparent(window, false)
		child.owner = self
	window.size_changed.connect(_fit_bottom_window)
	window.visibility_changed.connect(func():
		if window.visible:
			DisplayServer.window_set_input_event_callback(_route_bottom_input, window.get_window_id()))
	window.close_requested.connect(func(): SettingsManager.general.dual_screen = false)

func _show_bottom_window(shown: bool) -> void:
	var window := bottom_view as Window
	if window.visible == shown:
		return
	if not shown:
		_remember_bottom_window()
		window.hide()
		return
	_place_bottom_window()
	window.show()
	_fit_bottom_window()

func _fit_bottom_window() -> void:
	var window := bottom_view as Window
	if not window or not window.visible:
		return
	var size := Vector2(window.size).max(Vector2.ONE)
	window.content_scale_size = Vector2i(size)
	var screen_height := float(DisplayServer.screen_get_size(window.current_screen).y)
	var scale := maxf(screen_height, PC_SCALE_HEIGHT * 0.5) / PC_SCALE_HEIGHT
	window.content_scale_factor = minf(scale * SettingsManager.theme.ui_scale, minf(size.x, size.y) / MIN_UI_SIZE)

func _place_bottom_window() -> void:
	var window := bottom_view as Window
	var saved := SettingsManager.general.bottom_window.split(",")
	if saved.size() == 4:
		var rect := Rect2i(int(saved[0]), int(saved[1]), maxi(int(saved[2]), BOTTOM_MIN_SIZE.x), maxi(int(saved[3]), BOTTOM_MIN_SIZE.y))
		for screen in DisplayServer.get_screen_count():
			if DisplayServer.screen_get_usable_rect(screen).intersects(rect):
				window.position = rect.position
				window.size = rect.size
				return
	var main := get_window()
	var home := main.current_screen
	var target := (home + 1) % DisplayServer.get_screen_count()
	var area := DisplayServer.screen_get_usable_rect(target)
	var scale := maxf(float(DisplayServer.screen_get_size(target).y), PC_SCALE_HEIGHT * 0.5) / PC_SCALE_HEIGHT * SettingsManager.theme.ui_scale
	var size := Vector2i(BOTTOM_SIZE * scale).clamp(BOTTOM_MIN_SIZE, area.size)
	var position := area.position + (area.size - size) / 2
	if target == home:
		position = Vector2i(main.position.x + main.size.x + BOTTOM_GAP, main.position.y + main.size.y - size.y)
		position = position.clamp(area.position, area.end - size)
	window.size = size
	window.position = position

func _remember_bottom_window() -> void:
	var window := bottom_view as Window
	if window and window.visible:
		SettingsManager.general.bottom_window = "%d,%d,%d,%d" % [window.position.x, window.position.y, window.size.x, window.size.y]

func _route_bottom_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton or event is InputEventJoypadMotion:
		return
	if event is InputEventMouse or event is InputEventScreenTouch or event is InputEventScreenDrag or event is InputEventGesture:
		InputGlyphs.observe(event)
		_wake()
		bottom_view.push_input(event)
	else:
		get_viewport().push_input(event)

func _forward_links() -> bool:
	if not Engine.has_singleton("MusicService"):
		return false
	var service: Object = Engine.get_singleton("MusicService")
	if service.linksForwarded():
		get_tree().quit()
		return true
	for target: String in service.launchTargets():
		MediaPlayer.open_target.call_deferred(target)
	return false

func _quit() -> void:
	_remember_bottom_window()
	get_tree().auto_accept_quit = true
	get_tree().quit()

func _set_window_visible(visible: bool) -> void:
	var window := get_window()
	if visible:
		if _in_tray and Engine.has_singleton("MusicService"):
			Engine.get_singleton("MusicService").setWindowVisible(true)
		_leave_tray()
		if window.mode == Window.MODE_MINIMIZED:
			window.mode = _restore_mode
		DisplayServer.window_move_to_foreground()
		window.grab_focus()
		if bottom_view is Window:
			_show_bottom_window(Main.dual)
	elif not _in_tray:
		if bottom_view is Window:
			_show_bottom_window(false)
		if window.mode != Window.MODE_MINIMIZED:
			_restore_mode = window.mode
		_in_tray = true
		_physics_ticks = Engine.physics_ticks_per_second
		Engine.physics_ticks_per_second = TRAY_FPS
		RenderingServer.render_loop_enabled = false
		Engine.max_fps = TRAY_FPS
		if not (Engine.has_singleton("MusicService") and Engine.get_singleton("MusicService").setWindowVisible(false)):
			window.mode = Window.MODE_MINIMIZED

func _leave_tray() -> void:
	if not _in_tray:
		return
	_in_tray = false
	Engine.physics_ticks_per_second = _physics_ticks
	RenderingServer.render_loop_enabled = true
	_wake()

func _on_tray_command(command: String) -> void:
	match command:
		"show":
			_set_window_visible(true)
		"toggle":
			MediaPlayer.toggle()
		"next":
			MediaPlayer.next()
		"previous":
			MediaPlayer.previous()
		"quit":
			_quit()

func _go_back() -> bool:
	var now := Time.get_ticks_msec()
	if now - _last_back_msec >= BACK_DEBOUNCE_MS:
		_last_back_msec = now
		_last_back_handled = Main.go_back()
	return _last_back_handled
