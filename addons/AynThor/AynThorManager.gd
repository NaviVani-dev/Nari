extends Node

@export_group("Screens")
@export var main_screen: Screen
@export var second_screen: Screen

@export var target_fps: int = 0:
	set(value):
		target_fps = value
		if renderer:
			renderer.set_target_fps(value)

@export var rotation_degrees: ScreenRotation = ScreenRotation.DEG_180:
	set(value):
		rotation_degrees = value
		if renderer:
			renderer.set_rotation_degrees(value)

@export var touch_logging: bool = false:
	set(value):
		touch_logging = value
		if ayn_thor_plugin:
			ayn_thor_plugin.set_touch_logging(value)
			
var _main_viewport: SubViewport
var _second_viewport: SubViewport
var _main_container: SubViewportContainer
var _second_container: SubViewportContainer

const SCREENS_META := "screens"

var ayn_thor_plugin = null
var renderer = null

var is_swapped: bool = false
var original_main_size: Vector2i
var original_second_size: Vector2i
var is_android: bool = false
var second_size_confirmed: bool = false
var last_touch_positions: Dictionary = {}
var has_second_screen: bool = false

var _surface_size: Vector2 = Vector2.ZERO
var _mouse_touch_index: int = -1

signal screens_swapped(swapped: bool)
signal second_screen_availability_changed(available: bool)

func _input(event: InputEvent) -> void:
	if InputMap.has_action("swap") and event.is_action_pressed("swap"):
		swap_screens()
		
func _ready():
	is_android = OS.get_name() == "Android"

	if ClassDB.class_exists("AynThorRenderer"):
		renderer = get_node_or_null("AynThorRenderer")
		if not renderer:
			renderer = ClassDB.instantiate("AynThorRenderer")
			add_child(renderer)
			renderer.name = "AynThorRenderer"
		renderer.set_target_fps(target_fps)
		renderer.set_rotation_degrees(rotation_degrees)
	
	if Engine.has_singleton("AynThor"):
		if main_screen:
			main_screen.setup(self)
			if main_screen.viewport: _main_viewport = main_screen.viewport
			if main_screen.container: _main_container = main_screen.container
			
		if second_screen:
			second_screen.setup(self)
			if second_screen.container: _second_container = second_screen.container
			if second_screen.viewport: _second_viewport = second_screen.viewport
		
		ayn_thor_plugin = Engine.get_singleton("AynThor")
		ayn_thor_plugin.connect("second_screen_connected", _on_screen_connected)
		ayn_thor_plugin.connect("second_screen_disconnected", _on_screen_disconnected)
		ayn_thor_plugin.connect("second_screen_resized", _on_screen_resized)
		ayn_thor_plugin.connect("second_screen_input", _on_second_screen_input)
		ayn_thor_plugin.set_touch_logging(touch_logging)
		ayn_thor_plugin.init_screen()
		_set_second_screen_available(ayn_thor_plugin.has_second_screen())
	
	original_main_size = get_viewport().size
	if original_main_size.x == 0:
		original_main_size = Vector2i(1920, 1080)
	
	original_second_size = Vector2i(854, 480)
	
	_update_detached_viewports()

	if _main_viewport:
		_main_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_main_viewport.size = original_main_size
	if _second_viewport:
		_second_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		_second_viewport.size = original_second_size

	if _main_container:
		_main_container.position = Vector2.ZERO
	if _second_container:
		_second_container.position = Vector2(-10000, 0)

	RenderingServer.frame_post_draw.connect(_draw_second_screen)

var skip_frames: int = 0

func _draw_second_screen():
	if skip_frames > 0:
		skip_frames -= 1
		return

	var available: bool = renderer != null and renderer.is_window_available()
	var detached := _main_viewport if is_swapped else _second_viewport
	_publish_screen(detached if available else null)
	if detached:
		var mode := SubViewport.UPDATE_ALWAYS if available else SubViewport.UPDATE_DISABLED
		if detached.render_target_update_mode != mode:
			detached.render_target_update_mode = mode
	if not available:
		return

	if not second_size_confirmed:
		_try_update_second_screen_size()

	var texture_to_draw = _main_viewport if is_swapped else _second_viewport
	if texture_to_draw:
		renderer.draw_viewport_texture(RenderingServer.viewport_get_texture(texture_to_draw.get_viewport_rid()))

func _publish_screen(viewport: SubViewport) -> void:
	var screens: Array = []
	if viewport and _surface_size != Vector2.ZERO:
		screens.append({"viewport": viewport, "rotation": wrapi(rotation_degrees - ScreenRotation.DEG_180, 0, 360), "size": _surface_size})
	var root := get_tree().root
	if root.get_meta(SCREENS_META, []) != screens:
		root.set_meta(SCREENS_META, screens)

func _try_update_second_screen_size():
	if renderer and renderer.is_window_available():
		var size = renderer.get_second_screen_size()
		if size != Vector2i.ZERO:
			original_second_size = size
			second_size_confirmed = true
			if _surface_size == Vector2.ZERO:
				_surface_size = Vector2(size)
			if not is_swapped and _second_viewport:
				_second_viewport.size = original_second_size

func fit_main_screen():
	original_main_size = Vector2i(get_viewport().get_visible_rect().size)
	var viewport := _second_viewport if is_swapped else _main_viewport
	var container := _second_container if is_swapped else _main_container
	if viewport:
		viewport.size = original_main_size
	if container:
		container.update_minimum_size()
		container.position = Vector2.ZERO
		container.size = original_main_size

func swap_screens():
	is_swapped = !is_swapped
	
	var second_size = original_second_size
	if renderer and renderer.is_window_available():
		var s = renderer.get_second_screen_size()
		if s != Vector2i.ZERO:
			second_size = s
			original_second_size = s

	if is_swapped:
		if _main_container:
			_main_container.position = Vector2(-10000, 0)
			_main_container.size = second_size
		if _second_container:
			_second_container.position = Vector2.ZERO
			_second_container.size = original_main_size
		
		if _second_viewport:
			_second_viewport.size = original_main_size
		if _main_viewport:
			_main_viewport.size = second_size
	else:
		if _main_container:
			_main_container.position = Vector2.ZERO
			_main_container.size = original_main_size
		if _second_container:
			_second_container.position = Vector2(-10000, 0)
			_second_container.size = second_size
		
		if _main_viewport:
			_main_viewport.size = original_main_size
		if _second_viewport:
			_second_viewport.size = second_size

	_update_detached_viewports()

	screens_swapped.emit(is_swapped)
	skip_frames = 2

func _update_detached_viewports():
	_set_viewport_detached(_second_viewport, _second_container, not is_swapped)
	_set_viewport_detached(_main_viewport, _main_container, is_swapped)

func _set_viewport_detached(viewport: SubViewport, container: SubViewportContainer, detached: bool):
	if not viewport or not container:
		return
	if detached and viewport.get_parent() == container:
		viewport.reparent(self)
	elif not detached and viewport.get_parent() == self:
		viewport.reparent(container)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS

func _on_second_screen_input(action: int, x: float, y: float, pid: int):
	var target_vp = _main_viewport if is_swapped else _second_viewport
	if not target_vp or _surface_size.x <= 0 or _surface_size.y <= 0:
		return

	var normalized = Vector2(x / _surface_size.x, y / _surface_size.y)
	match wrapi(rotation_degrees - ScreenRotation.DEG_180, 0, 360):
		90: normalized = Vector2(normalized.y, 1.0 - normalized.x)
		180: normalized = Vector2(1.0 - normalized.x, 1.0 - normalized.y)
		270: normalized = Vector2(1.0 - normalized.y, normalized.x)
	var current_pos = normalized * Vector2(target_vp.size)

	if action == 0 or action == 5:
		last_touch_positions[pid] = current_pos
		var touch = InputEventScreenTouch.new()
		touch.pressed = true
		touch.index = pid
		touch.position = current_pos
		target_vp.push_input(touch, true)
		if _mouse_touch_index == -1:
			_mouse_touch_index = pid
			_push_emulated_click(target_vp, current_pos, true)
	elif action == 1 or action == 3 or action == 6:
		last_touch_positions.erase(pid)
		var touch = InputEventScreenTouch.new()
		touch.pressed = false
		touch.canceled = action == 3
		touch.index = pid
		touch.position = current_pos
		target_vp.push_input(touch, true)
		if _mouse_touch_index == pid:
			_mouse_touch_index = -1
			_push_emulated_click(target_vp, current_pos, false)
	elif action == 2:
		var relative = current_pos - last_touch_positions.get(pid, current_pos)
		last_touch_positions[pid] = current_pos
		var drag = InputEventScreenDrag.new()
		drag.index = pid
		drag.position = current_pos
		drag.relative = relative
		target_vp.push_input(drag, true)
		if _mouse_touch_index == pid:
			var motion = InputEventMouseMotion.new()
			motion.position = current_pos
			motion.global_position = current_pos
			motion.relative = relative
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
			target_vp.push_input(motion, true)

	if touch_logging:
		print("AynThor touch: action=", action, " raw=", Vector2(x, y), " surface=", _surface_size,
			" -> viewport=", current_pos, " of ", target_vp.size,
			" hovered=", target_vp.gui_get_hovered_control(),
			" focus=", target_vp.gui_get_focus_owner())

func _push_emulated_click(viewport: SubViewport, position: Vector2, pressed: bool):
	var click = InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	click.pressed = pressed
	click.position = position
	click.global_position = position
	viewport.push_input(click, true)

func _set_second_screen_available(available: bool):
	if has_second_screen == available:
		return
	has_second_screen = available
	second_screen_availability_changed.emit(available)

func _on_screen_resized(width: int, height: int):
	_surface_size = Vector2(width, height)

func _on_screen_connected():
	_set_second_screen_available(true)
	_update_detached_viewports()
	_try_update_second_screen_size()

func _on_screen_disconnected():
	_set_second_screen_available(false)
	_surface_size = Vector2.ZERO
	second_size_confirmed = false
	last_touch_positions.clear()
	_mouse_touch_index = -1

func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if ayn_thor_plugin:
			ayn_thor_plugin.destroy_screen()

enum ScreenRotation {
	DEG_0 = 0,
	DEG_90 = 90,
	DEG_180 = 180,
	DEG_270 = 270
}
