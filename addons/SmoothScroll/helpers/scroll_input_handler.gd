class_name ScrollInputHandler
extends RefCounted

var _container: SmoothScrollContainer = null

var speed: float = 1000.0

var drag_with_mouse: bool = true

var drag_with_touch: bool = true

var handle_input: bool = true

var content_dragging: bool = false

var content_dragging_moved: bool = false

var is_in_deadzone: bool = false

var h_scrollbar_dragging: bool = false

var v_scrollbar_dragging: bool = false

var mouse_on_scrollbar: bool = false

var drag_temp_data: Array = []

var _scrollbar_grab: float = 0.0

var _drag_travel: Vector2 = Vector2.ZERO

var _drag_vertical: bool = true

static var _touch_seen: bool = false

func _init(container: SmoothScrollContainer) -> void:
	_container = container

func process_gui_input(event: InputEvent) -> void:

	if _container.hide_scrollbar_over_time and event is InputEventMouseMotion:
		_container.scrollbar_animator.show_scrollbars()
	

	if event is InputEventMouseButton:
		_process_mouse_button(event)
	

	if (event is InputEventScreenDrag and drag_with_touch) \
			or (event is InputEventMouseMotion and drag_with_mouse and not _touch_seen):
		_process_drag_motion(event)
	

	if event is InputEventPanGesture:
		_process_pan_gesture(event)
	

	if event is InputEventScreenTouch:
		_process_screen_touch(event)
	

	if handle_input:
		_container.get_viewport().set_input_as_handled()

func process_scrollbar_input(event: InputEvent, vertical: bool) -> void:
	var bar: ScrollBar = _container.get_v_scroll_bar() if vertical else _container.get_h_scroll_bar()
	if event is InputEventMouseButton:

		if event.button_index in [
			MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_UP,
			MOUSE_BUTTON_WHEEL_LEFT,
			MOUSE_BUTTON_WHEEL_RIGHT
		]:
			process_gui_input(event)


		if event.button_index == MOUSE_BUTTON_LEFT:
			_handle_scrollbar_drag_button(event, vertical)
			_move_scrollbar(bar, event.position, vertical, event.pressed)
			bar.accept_event()

	if event is InputEventScreenTouch:
		_handle_scrollbar_touch(event, vertical)
		_move_scrollbar(bar, event.position, vertical, event.pressed)
		bar.accept_event()

	var dragging: bool = v_scrollbar_dragging if vertical else h_scrollbar_dragging
	if dragging and (event is InputEventMouseMotion or event is InputEventScreenDrag):
		_move_scrollbar(bar, event.position, vertical, false)
		bar.accept_event()


func _move_scrollbar(bar: ScrollBar, at: Vector2, vertical: bool, pressed: bool) -> void:
	var axis: int = 1 if vertical else 0
	var style: StyleBox = bar.get_theme_stylebox("scroll")
	var track: float = bar.size[axis] - style.get_minimum_size()[axis]
	var total: float = bar.max_value - bar.min_value
	if total <= bar.page or track <= 0.0:
		return
	var grabber: float = clampf(track * bar.page / total, bar.get_theme_stylebox("grabber").get_minimum_size()[axis], track)
	var travel: float = track - grabber
	var along: float = at[axis] - style.get_margin(SIDE_TOP if vertical else SIDE_LEFT)
	if pressed:
		var grabber_start: float = travel * (bar.value - bar.min_value) / (total - bar.page)
		var on_grabber: bool = along >= grabber_start and along <= grabber_start + grabber
		_scrollbar_grab = along - grabber_start if on_grabber else grabber * 0.5
	if travel > 0.0:
		bar.value = bar.min_value + clampf((along - _scrollbar_grab) / travel, 0.0, 1.0) * (total - bar.page)

func on_mouse_scrollbar(entered: bool) -> void:
	mouse_on_scrollbar = entered

func any_scrollbar_dragging() -> bool:
	return h_scrollbar_dragging or v_scrollbar_dragging

func init_drag_temp_data() -> void:
	var spare_size: Vector2 = ScrollLayout.get_spare_size(_container, _container.content_margins)
	var content_node_size_diff: Vector2 = ScrollLayout.get_child_size_diff(
		_container.content_node,
		spare_size,
		true,
		true
	)
	var content_node_boundary_dist: Vector4 = ScrollLayout.get_boundary_dist(
		_container.pos,
		content_node_size_diff
	)
	_drag_travel = Vector2.ZERO
	drag_temp_data = [
		0.0,
		0.0,
		_container.pos.x,
		_container.pos.y,
		content_node_boundary_dist.x,
		content_node_boundary_dist.y,
		content_node_boundary_dist.z,
		content_node_boundary_dist.w,
	]

func _process_mouse_button(event: InputEventMouseButton) -> void:
	match event.button_index:
		MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed:
				_handle_wheel_scroll(event, false, true)
		MOUSE_BUTTON_WHEEL_UP:
			if event.pressed:
				_handle_wheel_scroll(event, true, true)
		MOUSE_BUTTON_WHEEL_LEFT:
			if event.pressed:
				_handle_wheel_scroll(event, true, false)
		MOUSE_BUTTON_WHEEL_RIGHT:
			if event.pressed:
				_handle_wheel_scroll(event, false, false)
		MOUSE_BUTTON_LEFT:
			if _touch_seen:
				return
			if event.pressed:
				_start_content_drag()
			else:
				_end_content_drag()

func _handle_wheel_scroll(event: InputEventMouseButton, positive: bool, is_vertical: bool) -> void:
	_container.last_scroll_type = SmoothScrollContainer.SCROLL_TYPE.WHEEL
	_container.scroll_damper = _container.wheel_scroll_damper
	_container.scrollbar_animator.kill_scroll_tweens()
	
	var amount: float = speed * event.factor * (1.0 if positive else -1.0)
	

	if is_vertical:
		if event.shift_pressed or not _container.should_scroll_vertical():
			if _container.should_scroll_horizontal():
				_container.velocity.x += amount
		else:
			if _container.should_scroll_vertical():
				_container.velocity.y += amount
	else:
		if event.shift_pressed:
			if _container.should_scroll_vertical():
				_container.velocity.y += amount if positive else -amount
		else:
			if _container.should_scroll_horizontal():
				_container.velocity.x += amount

func _start_content_drag() -> void:
	if not drag_with_mouse: return
	
	content_dragging = true
	is_in_deadzone = true
	_container.scroll_damper = _container.dragging_scroll_damper
	_container.last_scroll_type = SmoothScrollContainer.SCROLL_TYPE.DRAG
	init_drag_temp_data()
	_container.scrollbar_animator.kill_scroll_tweens()

func _end_content_drag() -> void:
	_notify_scroll_end()
	content_dragging = false
	is_in_deadzone = false

func _process_drag_motion(event) -> void:
	if not content_dragging: return
	
	if is_in_deadzone:
		_drag_travel += event.relative
		var deadzone: int = _container.scroll_deadzone
		if abs(_drag_travel.x) <= deadzone and abs(_drag_travel.y) <= deadzone:
			return
		
		_drag_vertical = abs(_drag_travel.y) >= abs(_drag_travel.x)
		if not (_container.should_scroll_vertical() if _drag_vertical else _container.should_scroll_horizontal()):
			content_dragging = false
			is_in_deadzone = false
			return
		
		is_in_deadzone = false

		drag_temp_data[0] = 0.0
		drag_temp_data[1] = 0.0

		_container.propagate_notification(Control.NOTIFICATION_SCROLL_BEGIN)
	elif _drag_vertical:
		drag_temp_data[1] += event.relative.y
	else:
		drag_temp_data[0] += event.relative.x
	
	_container.handle_content_dragging()

func _process_pan_gesture(event: InputEventPanGesture) -> void:
	if _container.should_scroll_horizontal():
		_container.velocity.x = -event.delta.x * speed
		_container.scrollbar_animator.kill_scroll_tweens()
	if _container.should_scroll_vertical():
		_container.velocity.y = -event.delta.y * speed
		_container.scrollbar_animator.kill_scroll_tweens()

func _process_screen_touch(event: InputEventScreenTouch) -> void:
	_touch_seen = true
	if event.pressed:
		if not drag_with_touch:
			return
		
		content_dragging = true
		is_in_deadzone = true
		_container.scroll_damper = _container.dragging_scroll_damper
		_container.last_scroll_type = SmoothScrollContainer.SCROLL_TYPE.DRAG
		init_drag_temp_data()
		_container.scrollbar_animator.kill_scroll_tweens()
	else:
		_notify_scroll_end()
		content_dragging = false
		is_in_deadzone = false

func _handle_scrollbar_drag_button(event: InputEventMouseButton, vertical: bool) -> void:
	if event.pressed:
		if vertical:
			v_scrollbar_dragging = true
		else:
			h_scrollbar_dragging = true
		_container.last_scroll_type = SmoothScrollContainer.SCROLL_TYPE.BAR
		_container.scrollbar_animator.kill_scroll_tweens()
	else:
		if vertical:
			v_scrollbar_dragging = false
		else:
			h_scrollbar_dragging = false

func _handle_scrollbar_touch(event: InputEventScreenTouch, vertical: bool) -> void:
	if event.pressed:
		if vertical:
			v_scrollbar_dragging = true
		else:
			h_scrollbar_dragging = true
		_container.last_scroll_type = SmoothScrollContainer.SCROLL_TYPE.BAR
		_container.scrollbar_animator.kill_scroll_tweens()
	else:
		if vertical:
			v_scrollbar_dragging = false
		else:
			h_scrollbar_dragging = false

func _notify_scroll_end() -> void:
	if content_dragging and not is_in_deadzone:
		_container.propagate_notification(Control.NOTIFICATION_SCROLL_END)
