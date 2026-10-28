extends Node

signal page_changed(page: Pages, data: Dictionary)
signal insets_changed(insets: Vector4)
signal dual_changed(enabled: bool)
signal header_changed

enum Pages { Home, Tracks, Albums, Artists, Playlists, Album, Artist, Playlist, NowPlaying, Settings, Soundboard, Welcome, Search, About, Discover, Web, Marketplace, Folders }

const PAGE_SCENES := {
	Pages.Home: "Home",
	Pages.Tracks: "Tracks",
	Pages.Albums: "Albums",
	Pages.Artists: "Artists",
	Pages.Playlists: "Playlists",
	Pages.Album: "Album",
	Pages.Artist: "Artist",
	Pages.Playlist: "Playlist",
	Pages.NowPlaying: "NowPlaying",
	Pages.Settings: "Settings",
	Pages.Soundboard: "Soundboard",
	Pages.Welcome: "Welcome",
	Pages.Search: "Search",
	Pages.About: "About",
	Pages.Discover: "Discover",
	Pages.Web: "Web",
	Pages.Marketplace: "Marketplace",
	Pages.Folders: "Folders",
}
const SCREENS_PATH := "res://ui/screens/%s/%s.tscn"
const FADE_TIME := 0.15
const TRANSITION_TIME := 0.22
const TRANSITION_SHIFT := 0.3
const PAGE_TRANSITIONS := ["slide", "fade", "none"]
const CONTENT_FADE := 0.3
const HINTS_NAME := "AppHints"
const SETUP_FILE := "user://OOBE.txt"
const MARGINS := ["margin_left", "margin_top", "margin_right", "margin_bottom"]
const BLEED_GROUP := "full_bleed"
const PRELOAD_IDLE_MS := 600

var setup_done := FileAccess.file_exists(SETUP_FILE)
var loading_held := true
var dual := true
var insets := Vector4.ZERO
var shortcuts: Array = []
var header_shown := false
var header_subtitle := ""
var header_actions: Array = []
var reduce_motion := false
var current_page: Pages = Pages.Home
var current_data: Dictionary = {}
var hints_reserve: Array[float] = [0.0, 0.0]
var bar_reserve: Array[float] = [0.0, 0.0]

var _scenes: Dictionary = {}
var _requested: Dictionary = {}
var _top_view: Node
var _bottom_view: Node
var _page: Page
var _containers: Dictionary = {}
var _margins: Dictionary = {}
var _history: Array[Dictionary] = []
var _forward: Array[Dictionary] = []
var _going_forward := false
var _opened_now_playing := false
var _had_song := false
var _dialogs: Array[Dialog] = []
var _content_hidden := false
var _content_fade: Tween
var _last_input := 0
var _preloading := false
var _preload_again := false

func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	get_tree().root.gui_focus_changed.connect(_on_control_hovered)
	get_tree().root.window_input.connect(func(_event: InputEvent): _last_input = Time.get_ticks_msec())
	loading_held = not setup_done or SettingsManager.general.boot_intro
	_had_song = not str(MediaPlayer.get_playback_state().get("current_id", "")).is_empty()
	MediaPlayer.playback_changed.connect(_on_playback_changed)
	InputGlyphs.mode_changed.connect(_on_mode_changed)
	MediaPlayer.now_playing_requested.connect(func():
		if not loading_held and _top_view and current_page != Pages.NowPlaying:
			open_now_playing())

func _exit_tree() -> void:
	Worker.finish()

func _on_mode_changed(_gamepad: bool) -> void:
	if InputGlyphs.navigating() or not _top_view:
		return
	var focused := focus_owner()
	if focused and not focused is LineEdit:
		_viewport_of(input_view()).gui_release_focus()

func register_screens(top_view: Node, bottom_view: Node, top_container: MarginContainer, bottom_container: MarginContainer) -> void:
	_top_view = top_view
	_bottom_view = bottom_view
	_containers = {top_view: top_container}
	if bottom_view:
		_containers[bottom_view] = bottom_container
	for container: MarginContainer in _containers.values():
		var base := Vector4()
		for side in 4:
			base[side] = container.get_theme_constant(MARGINS[side])
		_margins[container] = base
	_apply_margins()
	MediaPlayer.library_loading_changed.connect(_on_library_loading_changed)
	if not loading_held and MediaPlayer.is_library_pending():
		_set_content_visible(false, true)
	dual_changed.emit(dual)

func _on_library_loading_changed(loading: bool) -> void:
	if loading_held:
		return
	if loading:
		_set_content_visible(false)
		return
	if not _content_hidden:
		return
	await get_tree().create_timer(CONTENT_FADE).timeout
	if _content_hidden and not MediaPlayer.library_loading:
		_set_content_visible(true)

func _set_content_visible(shown: bool, instant: bool = false) -> void:
	_content_hidden = not shown
	if _content_fade:
		_content_fade.kill()
	var pages: Array = [_page.top, _page.bottom] if _page else []
	pages = pages.filter(func(node): return is_instance_valid(node))
	var fading: Array = pages + [_top_view, _bottom_view].map(func(view): return view.get_node_or_null(HINTS_NAME) if view else null).filter(func(node): return is_instance_valid(node))
	var target := 1.0 if shown else 0.0
	if not shown:
		_viewport_of(input_view()).gui_release_focus()
	if instant:
		for node in fading:
			node.modulate.a = target
		for page in pages:
			page.visible = shown
		return
	for page in pages:
		if shown:
			page.show()
	_content_fade = create_tween().set_parallel(true)
	for node in fading:
		_content_fade.tween_property(node, "modulate:a", target, CONTENT_FADE)
	_content_fade.chain().tween_callback(func():
		for page in pages:
			if is_instance_valid(page):
				page.visible = shown
		if shown and not focus_owner():
			focus_content())

func change_page(page: Pages, data: Dictionary = {}, keep_history: bool = true, focus: int = 0) -> void:
	if not _top_view:
		return
	if _page and page == current_page and data == current_data:
		return
	for dialog in _dialogs.duplicate():
		dialog.close()
	if _page and keep_history and not _page.get("transient"):
		_history.push_back({"page": current_page, "data": _page_data(), "focus": _page_focus()})
	if keep_history and not _going_forward:
		_forward.clear()
	hide_header()
	var instance: Page = _scene(SCREENS_PATH % ["dual" if dual else "single", PAGE_SCENES[page]]).instantiate()
	instance.data = data
	instance.focus_index = focus
	current_page = page
	current_data = data
	var leaving := _page
	_page = null
	if leaving:
		_slide_out(leaving)
	shortcuts = []
	instance.remove_child(instance.top)
	_mount(instance.top, _top_view)
	if instance.bottom and dual:
		instance.remove_child(instance.bottom)
		_mount(instance.bottom, _bottom_view)
	elif instance.bottom:
		instance.bottom.free()
		instance.bottom = null
	add_child(instance)
	_page = instance
	page_changed.emit(page, data)

func has_second_screen() -> bool:
	return Engine.has_singleton("AynThor") and Engine.get_singleton("AynThor").has_second_screen()

func can_toggle_dual() -> bool:
	return OS.has_feature("pc") or has_second_screen()

func set_dual(enabled: bool) -> void:
	InputGlyphs.set_dual(enabled)
	if dual == enabled:
		return
	dual = enabled
	_apply_margins()
	dual_changed.emit(dual)
	if _containers.is_empty():
		return
	for dialog in _dialogs.duplicate():
		dialog.close()
	reload_page()
	preload_pages()

func reload_page() -> void:
	if not _page:
		return
	var focus := _page_focus()
	var state := _page_data()
	_slide_out(_page)
	_page = null
	change_page(current_page, state, false, focus)

func set_insets(value: Vector4) -> void:
	insets = value
	_apply_margins()
	insets_changed.emit(insets)

func set_hints_reserve(screen: int, height: float) -> void:
	if is_equal_approx(height, hints_reserve[screen]):
		return
	hints_reserve[screen] = height
	_apply_margins()

func set_bar_reserve(screen: int, height: float) -> void:
	if is_equal_approx(height, bar_reserve[screen]):
		return
	bar_reserve[screen] = height
	_apply_margins()

func set_shortcuts(value: Array) -> void:
	shortcuts = value

func set_header(subtitle: String, actions: Array) -> void:
	header_shown = true
	header_subtitle = subtitle
	header_actions = actions
	header_changed.emit()

func hide_header() -> void:
	header_shown = false
	header_subtitle = ""
	header_actions = []
	header_changed.emit()

func trigger_shortcut(event: InputEvent) -> bool:
	for shortcut: Dictionary in shortcuts + header_actions:
		var action: Callable = shortcut.get("action", Callable())
		var input := InputGlyphs.action_of(shortcut.get("glyph", -1))
		if action.is_valid() and not input.is_empty() and event.is_action_pressed(input):
			action.call()
			return true
	return false

func _on_node_added(node: Node) -> void:
	if node is SmoothScrollContainer:
		node.add_child.call_deferred(EdgeScrollbar.new(node), false, Node.INTERNAL_MODE_BACK)
	if node is Control:
		var hovered: = _on_control_hovered.bind(node)
		if not node.mouse_entered.is_connected(hovered):
			node.mouse_entered.connect(hovered)
	elif node is Viewport and not node.gui_focus_changed.is_connected(_on_control_hovered):
		node.gui_focus_changed.connect(_on_control_hovered)
	if node.has_signal("selection_changed") and not node.selection_changed.is_connected(_on_selection_changed):
		node.selection_changed.connect(_on_selection_changed)

func _on_selection_changed(_index: int) -> void:
	haptic()

func _on_control_hovered(control: Control) -> void:
	if control.focus_mode != Control.FOCUS_NONE:
		haptic()

func haptic(strength: float = 1.0) -> void:
	if not SettingsManager.general.haptics:
		return
	strength = clampf(strength, 0.0, 1.0)
	for device in Input.get_connected_joypads():
		Input.start_joy_vibration(device, 0.6 * strength, 0.3 * strength, 0.1)
	Input.vibrate_handheld(15, 0.3 * strength)

func frame_edge(node: Node) -> Vector2:
	for view in _containers:
		var container: MarginContainer = _containers[view]
		if container.is_ancestor_of(node):
			var rect := container.get_global_rect()
			var right := float(container.get_theme_constant("margin_right"))
			return Vector2(rect.end.x - (right - _margins[container].z), rect.end.x - right)
	var end := (node as CanvasItem).get_viewport_rect().end.x
	return Vector2(end, end)

func _apply_margins() -> void:
	for view in _containers:
		var container: MarginContainer = _containers[view]
		var margins: Vector4 = _margins[container]
		if view == _top_view:
			margins += insets
		margins.y += bar_reserve[0 if view == _top_view else 1]
		margins.w += hints_reserve[0 if view == _top_view else 1]
		for side in 4:
			container.add_theme_constant_override(MARGINS[side], roundi(margins[side]))
		_bleed(view)

func _bleed(view: Node, root: Node = null) -> void:
	var container: MarginContainer = _containers.get(view)
	if not container:
		return
	var scope: Node = root if root else container
	for node in get_tree().get_nodes_in_group(BLEED_GROUP):
		if node is Control and scope.is_ancestor_of(node):
			node.offset_left = -container.get_theme_constant("margin_left")
			node.offset_top = -container.get_theme_constant("margin_top")
			node.offset_right = container.get_theme_constant("margin_right")
			node.offset_bottom = container.get_theme_constant("margin_bottom")

func input_view() -> Node:
	return _bottom_view if dual and _bottom_view else _top_view

func input_root() -> Node:
	return _dialogs.back() if not _dialogs.is_empty() else input_view()

func get_page() -> Page:
	return _page

func can_go_back() -> bool:
	return not _history.is_empty()

func has_dialog() -> bool:
	return not _dialogs.is_empty()

func has_song() -> bool:
	return not str(MediaPlayer.get_playback_state().get("current_id", "")).is_empty()

func focus_owner() -> Control:
	return _viewport_of(input_view()).gui_get_focus_owner()

func preload_pages() -> void:
	if _preloading:
		_preload_again = true
		return
	_preloading = true
	await _preload_pages()
	_preloading = false
	if _preload_again:
		_preload_again = false
		preload_pages()

func _preload_pages() -> void:
	for page in PAGE_SCENES:
		var path: String = SCREENS_PATH % ["dual" if dual else "single", PAGE_SCENES[page]]
		if _scenes.has(path):
			continue
		for script: String in _scripts_of(path, {}):
			if not ResourceLoader.has_cached(script):
				while Time.get_ticks_msec() - _last_input < PRELOAD_IDLE_MS:
					await get_tree().process_frame
				if ResourceLoader.has_cached(script):
					continue
				load(script)
				await get_tree().process_frame
		if _scenes.has(path):
			continue
		if not _requested.has(path):
			if ResourceLoader.load_threaded_request(path) != OK:
				continue
			_requested[path] = true
		while _requested.has(path) and ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await get_tree().process_frame
		_scene(path)

func open_dialog(dialog: Dialog) -> void:
	var lock_page := func():
		if is_instance_valid(_input_page()):
			_input_page().focus_behavior_recursive = Control.FOCUS_BEHAVIOR_INHERITED if _dialogs.is_empty() else Control.FOCUS_BEHAVIOR_DISABLED
	var previous: WeakRef = weakref(focus_owner()) if _dialogs.is_empty() and focus_owner() else null
	_dialogs.append(dialog)
	input_view().add_child(dialog)
	_viewport_of(input_view()).gui_release_focus()
	lock_page.call()
	dialog.closed.connect(func():
		_dialogs.erase(dialog)
		lock_page.call()
		var target: Control = previous.get_ref() if previous else null
		if _dialogs.is_empty() and target and target.is_visible_in_tree():
			target.grab_focus())

func focus_content() -> void:
	if not _dialogs.is_empty():
		_dialogs.back().focus()
	elif _page and _page.has_method("focus_content"):
		_page.focus_content()
	elif _page and _page.get("list") is FocusScroll:
		_page.list.focus_item(0)

func go_back() -> bool:
	if not _dialogs.is_empty():
		if not _dialogs.back().locked:
			_dialogs.back().close()
		return true
	var focused: Node = focus_owner()
	while focused:
		if focused.has_method("go_back") and focused.go_back():
			return true
		focused = focused.get_parent()
	if _page and _page.get("locked"):
		return true
	if _page and _page.has_method("go_back") and _page.go_back():
		return true
	if _history.is_empty():
		return false
	var entry: Dictionary = _history.pop_back()
	if _page and not _page.get("transient"):
		_forward.push_back({"page": current_page, "data": _page_data(), "focus": _page_focus()})
	change_page(entry["page"], entry["data"], false, entry["focus"])
	return true

func can_go_forward() -> bool:
	return not _forward.is_empty()

func go_forward() -> bool:
	if _forward.is_empty() or not _dialogs.is_empty() or (_page and _page.get("locked")):
		return false
	var entry: Dictionary = _forward.pop_back()
	_going_forward = true
	change_page(entry["page"], entry["data"], true, entry["focus"])
	_going_forward = false
	return true

func go_home() -> void:
	_history.clear()
	_forward.clear()
	change_page(Pages.Home, {}, false)

func go_startup() -> void:
	var page: Pages = Pages.get(SettingsManager.general.startup_page, Pages.Home)
	if page == Pages.NowPlaying:
		page = Pages.Home
	_history.clear()
	_forward.clear()
	if page != Pages.Home:
		_history.push_back({"page": Pages.Home, "data": {}, "focus": 0})
	change_page(page, {}, false)

func finish_intro() -> void:
	if not setup_done:
		FileAccess.open(SETUP_FILE, FileAccess.WRITE)
		setup_done = true
	loading_held = false
	if MediaPlayer.is_library_pending():
		MediaPlayer.library_loading_changed.emit(true)
	go_startup()

func open_now_playing() -> void:
	change_page(Pages.NowPlaying)

func _on_playback_changed(state: Dictionary) -> void:
	var loaded := not str(state.get("current_id", "")).is_empty()
	if not loading_held and loaded and not _had_song and not _opened_now_playing and not MediaPlayer.resumed and _top_view:
		_opened_now_playing = true
		open_now_playing.call_deferred()
	_had_song = loaded

func _input_page() -> Control:
	if not _page:
		return null
	return _page.bottom if dual else _page.top

func _page_data() -> Dictionary:
	return _page.history_data() if _page.has_method("history_data") else current_data

func _page_focus() -> int:
	var list = _page.get("list")
	var selected: int = 0
	if _page.has_method("history_focus"):
		selected = _page.history_focus()
	elif list and list.has_method("get_selected"):
		selected = list.get_selected()
	return maxi(selected, 0)

func _scripts_of(path: String, seen: Dictionary) -> Array[String]:
	var scripts: Array[String] = []
	seen[path] = true
	for dependency: String in ResourceLoader.get_dependencies(path):
		var file := dependency.get_slice("::", 2) if dependency.contains("::") else dependency
		if seen.has(file):
			continue
		if file.ends_with(".gd"):
			seen[file] = true
			scripts.append(file)
		elif file.ends_with(".tscn"):
			scripts.append_array(_scripts_of(file, seen))
	return scripts

func _scene(path: String) -> PackedScene:
	if not _scenes.has(path):
		for pending: String in _requested.keys():
			var loaded := ResourceLoader.load_threaded_get(pending)
			if loaded:
				_scenes[pending] = loaded
		_requested.clear()
		if not _scenes.has(path):
			_scenes[path] = load(path)
	return _scenes[path]

func transition(key: String = "page_transition") -> Dictionary:
	var listed: Variant = Themes.active.get(key, "slide")
	var style: Dictionary = listed.duplicate() if listed is Dictionary else {"type": str(listed)}
	if not PAGE_TRANSITIONS.has(str(style.get("type", ""))):
		style["type"] = "slide"
	var material := ShaderMaterial.new()
	style["material"] = material if Themes.dress("transition", material, null) else null
	return style

func _process(_delta: float) -> void:
	for view: Node in _containers:
		if is_instance_valid(view):
			Themes.sway(_containers[view], "sway")
			if view.has_node(HINTS_NAME):
				Themes.sway(view.get_node(HINTS_NAME), "sway")

static func _physics_curve(config: Dictionary) -> PackedFloat32Array:
	var step := 1.0 / 60.0
	var keep := exp(-float(config.get("damping", 50.0)) * step)
	var distance := float(config.get("distance", 10.0))
	var limit := float(config.get("max_speed", 70.0)) * step
	var offset := distance
	var speed := 0.0
	var curve := PackedFloat32Array([1.0])
	while (absf(offset) > 0.001 or absf(speed) > 0.001) and curve.size() < 600:
		speed = clampf(keep * speed - (1.0 - keep) * offset * float(config.get("pull", 35.0)) * step, -limit, limit)
		offset += speed
		curve.append(offset / distance)
	return curve

func animate(tween: Tween, control: Control, style: Dictionary, entering: bool, distance: float) -> void:
	var time := float(style.get("duration" if entering else "exit", style.get("duration", TRANSITION_TIME)))
	var origin := control.position
	var shift := -distance * float(style.get("shift", TRANSITION_SHIFT))
	if style["type"] == "slide" and entering:
		control.position.y = origin.y + shift
	if style["type"] == "slide" and entering and style.get("physics") is Dictionary:
		var curve := _physics_curve(style["physics"])
		time = curve.size() / 60.0
		tween.tween_method(func(left: float): control.position.y = origin.y + shift * curve[mini(int(left * 60.0), curve.size() - 1)], 0.0, time, time)
	elif style["type"] == "slide":
		tween.tween_property(control, "position:y", origin.y if entering else origin.y + shift, time) \
			.set_trans(ClassDB.class_get_integer_constant("Tween", "TRANS_" + str(style.get("trans", "cubic")).to_upper())) \
			.set_ease(ClassDB.class_get_integer_constant("Tween", "EASE_" + str(style.get("ease", "out" if entering else "in")).to_upper()))
	if style["type"] != "none" and style.get("fade", true):
		if entering:
			control.modulate.a = 0.0
		tween.tween_property(control, "modulate:a", 1.0 if entering else 0.0, time)
	if entering and style.has("shake"):
		var span := float(style.get("shake_time", 0.6))
		tween.chain().tween_method(func(left: float):
			control.position = origin + Vector2(sin(19.913 * left), sin(21.913 * left)) * float(style["shake"]) * pow(1.0 - left / span, 2.0), 0.0, span, span)
	var material: ShaderMaterial = style["material"]
	if material:
		var overlay := ColorRect.new()
		overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		overlay.material = material
		material.set_shader_parameter("progress", 0.0 if entering else 1.0)
		material.set_shader_parameter("entering", entering)
		control.get_parent().add_child(overlay)
		overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		tween.tween_property(material, "shader_parameter/progress", 1.0 if entering else 0.0, time)
		tween.finished.connect(overlay.queue_free)

func _slide_out(page: Page) -> void:
	var top := page.top
	var bottom := page.bottom
	var remove := func():
		for node in [top, bottom]:
			if is_instance_valid(node):
				node.get_parent().queue_free()
		if is_instance_valid(page):
			page.queue_free()
	var style := transition()
	if style["type"] == "none" and not style["material"] or float(style.get("exit", 1.0)) <= 0.0:
		remove.call()
		return
	var tween := create_tween().set_parallel(true)
	if is_instance_valid(top) and _top_view:
		animate(tween, top, style, false, _view_height(_top_view))
	if is_instance_valid(bottom) and style["type"] != "none":
		tween.tween_property(bottom, "modulate:a", 0.0, float(style.get("exit", style.get("duration", TRANSITION_TIME))))
	tween.chain().tween_callback(remove)

func _viewport_of(view: Node) -> Viewport:
	return view if view is Viewport else view.get_viewport()

func _view_height(view: Node) -> float:
	return _viewport_of(view).get_visible_rect().size.y

func _mount(control: Control, view: Node) -> void:
	control.owner = null
	var holder := Control.new()
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_containers[view].add_child(holder)
	holder.add_child(control)
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_bleed(view, holder)
	control.visible = not _content_hidden
	var style := transition()
	control.modulate.a = 1.0
	if view != _top_view or style["type"] == "none" and not style["material"]:
		return
	animate(control.create_tween().set_parallel(true), control, style, true, _view_height(_top_view))
