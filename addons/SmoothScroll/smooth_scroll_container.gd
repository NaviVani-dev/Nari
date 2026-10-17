@tool
class_name SmoothScrollContainer
extends ScrollContainer

enum SCROLL_TYPE {

	WHEEL,

	BAR,

	DRAG
}


@export_group("Mouse Wheel")

@export_range(0.0, 10.0, 0.01, "or_greater", "hide_slider") var speed: float = 1000.0

@export var wheel_scroll_damper: ScrollDamper = ExpoScrollDamper.new()

@export_group("Dragging")

@export var dragging_scroll_damper: ScrollDamper = ExpoScrollDamper.new()

@export var drag_with_mouse: bool = true

@export var drag_with_touch: bool = true

@export_group("Container")

@export var just_snap_under: float = 0.4

@export_range(0, 50) var follow_focus_margin: int = 20

@export var allow_vertical_scroll: bool = true

@export var allow_horizontal_scroll: bool = true

@export var auto_allow_scroll: bool = true


@export var allow_overdragging: bool = true

@export_group("Scroll Bar")

@export var hide_scrollbar_over_time: bool = true:
	set(val): hide_scrollbar_over_time = _set_hide_scrollbar_over_time(val)

@export var scrollbar_hide_time: float = 3.0

@export var scrollbar_fade_in_time: float = 0.2

@export var scrollbar_fade_out_time: float = 0.5

@export_group("Input")

@export var handle_input: bool = true


@export var override_mouse_filters: bool = true:
	set(val): override_mouse_filters = _set_override_mouse_filters(val)

@export_group("Debug")

@export var debug_mode: bool = false

var velocity := Vector2.ZERO

var content_node: Control

var pos := Vector2(0, 0)

var scroll_damper: ScrollDamper

var is_scrolling: bool = false:
	set(val):
		if is_scrolling != val:
			if val:
				emit_signal("scroll_started")
			else:
				emit_signal("scroll_ended")
		is_scrolling = val

var last_scroll_type: SCROLL_TYPE:
	set(value):
		last_scroll_type = value
		following_focus = false


var following_focus: bool = false

var content_margins := Vector4.ZERO

var _initializing_margins: bool = false

var _base_offset := Vector2.ZERO

var _startup_done: bool = false

var _initial_margins_skipped: bool = false

var scrollbar_animator: ScrollbarAnimator

var input_handler: ScrollInputHandler

var _is_editor_hint = Engine.is_editor_hint()


var _last_ensure_size := Vector2.ZERO

var _size_stable_frames := 0

var _pending_ensure_control: Control = null

var _ensure_stability_timer: Timer = null

func _ready() -> void:
	if not ScrollDebugger.debug_gradient: ScrollDebugger.setup_debug_drawing()
	

	scroll_damper = wheel_scroll_damper
	scrollbar_animator = ScrollbarAnimator.new(self)
	scrollbar_animator.hide_time = scrollbar_hide_time
	scrollbar_animator.fade_in_time = scrollbar_fade_in_time
	scrollbar_animator.fade_out_time = scrollbar_fade_out_time
	

	input_handler = ScrollInputHandler.new(self)
	input_handler.speed = speed
	input_handler.drag_with_mouse = drag_with_mouse
	input_handler.drag_with_touch = drag_with_touch
	input_handler.handle_input = handle_input
	
	get_v_scroll_bar().gui_input.connect(_scrollbar_input.bind(true))
	get_h_scroll_bar().gui_input.connect(_scrollbar_input.bind(false))
	get_v_scroll_bar().mouse_entered.connect(_mouse_on_scroll_bar.bind(true))
	get_v_scroll_bar().mouse_exited.connect(_mouse_on_scroll_bar.bind(false))
	get_h_scroll_bar().mouse_entered.connect(_mouse_on_scroll_bar.bind(true))
	get_h_scroll_bar().mouse_exited.connect(_mouse_on_scroll_bar.bind(false))
	for bar: ScrollBar in [get_v_scroll_bar(), get_h_scroll_bar()]:
		bar.visibility_changed.connect(func():
			if bar.visible and hide_scrollbar_over_time and not _is_editor_hint:
				scrollbar_animator.show_scrollbars())
	get_viewport().gui_focus_changed.connect(_on_focus_changed)

	visibility_changed.connect(_visibility_changed)
	theme_changed.connect(_update_content_margins)
	

	if visible:
		call_deferred("_update_content_margins")
	else:
		_initial_margins_skipped = true

	for child: Node in get_children():
		if child is Control and not child is ScrollBar:
			content_node = child
			break
	
	if content_node:
		_base_offset = content_node.position
	
	if hide_scrollbar_over_time:
		scrollbar_animator.start_hide_timer()
	
	if override_mouse_filters:
		get_tree().node_added.connect(_on_node_added)
		if not _is_editor_hint:
			call_deferred("_apply_mouse_filters_to_children")
	

	set_process(false)

func _process(delta: float) -> void:
	if _is_editor_hint: return
	if _initializing_margins: return

	scroll(true, velocity.y, pos.y, delta)
	scroll(false, velocity.x, pos.x, delta)
	update_scrollbars()
	update_is_scrolling()

	if debug_mode: queue_redraw()
	
	if not is_scrolling:
		set_process(false)

func _mouse_on_scroll_bar(entered: bool) -> void:
	input_handler.on_mouse_scrollbar(entered)
	if entered and hide_scrollbar_over_time:
		scrollbar_animator.show_scrollbars()

func _scrollbar_input(event: InputEvent, vertical: bool) -> void:
	set_process(true)
	input_handler.process_scrollbar_input(event, vertical)

func _gui_input(event: InputEvent) -> void:
	set_process(true)
	input_handler.process_gui_input(event)

func _on_focus_changed(control: Control) -> void:
	if follow_focus and _startup_done and not input_handler.content_dragging and not input_handler.any_scrollbar_dragging():
		self.ensure_control_visible_smooth(control)

func _draw() -> void:
	if debug_mode: ScrollDebugger.draw_debug(self)

func _on_node_added(node: Node) -> void:
	if node is Control and is_ancestor_of(node):
		if override_mouse_filters:
			if not node.has_meta("_smooth_scroll_default_mouse_filter_set"):
				node.mouse_filter = Control.MOUSE_FILTER_PASS
				node.set_meta("_smooth_scroll_default_mouse_filter_set", true)

func _scrollbar_hide_timer_timeout() -> void:
	if scrollbar_animator.should_hide(input_handler.h_scrollbar_dragging, input_handler.v_scrollbar_dragging):
		scrollbar_animator.hide_scrollbars()

func _update_content_margins() -> void:
	set_process(true)
	_initializing_margins = true
	
	content_margins = ScrollLayout.get_content_margins(self)
	
	if content_node:
		_base_offset = ScrollLayout.calculate_base_offset(content_margins)
		
		if _initial_margins_skipped:
			pos = Vector2.ZERO
		
		if not _startup_done:
			velocity = Vector2.ZERO
	
	call_deferred("_end_margin_init")

func _end_margin_init() -> void:
	_initializing_margins = false
	_startup_done = true
	_initial_margins_skipped = false

func _visibility_changed() -> void:
	if visible and content_node:
		if _initial_margins_skipped:
			call_deferred("_update_content_margins")
		
		elif _startup_done:
			call_deferred("_update_content_margins")

func _set_hide_scrollbar_over_time(value: bool) -> bool:
	if value == false:
		if scrollbar_animator:
			scrollbar_animator.stop_hide_timer()
			scrollbar_animator.show_scrollbars_immediate()
	else:
		if scrollbar_animator:
			scrollbar_animator.start_hide_timer()
	return value

func _set_override_mouse_filters(value: bool) -> bool:
	if is_inside_tree():
		if value:
			if not get_tree().node_added.is_connected(_on_node_added):
				get_tree().node_added.connect(_on_node_added)
			if not _is_editor_hint:
				call_deferred("_apply_mouse_filters_to_children")
		else:
			if get_tree().node_added.is_connected(_on_node_added):
				get_tree().node_added.disconnect(_on_node_added)
	return value

func _apply_mouse_filters_to_children() -> void:
	_apply_mouse_filter_recursive(self)

func _apply_mouse_filter_recursive(node: Node) -> void:
	if node is Control and node != self and is_ancestor_of(node):
		if not node.has_meta("_smooth_scroll_default_mouse_filter_set"):
			node.mouse_filter = Control.MOUSE_FILTER_PASS
			node.set_meta("_smooth_scroll_default_mouse_filter_set", true)
	
	for child in node.get_children():
		_apply_mouse_filter_recursive(child)

func _get(property: StringName) -> Variant:
	match property:
		"scroll_horizontal":
			if not content_node: return 0
			return -int(pos.x)
		
		"scroll_vertical":
			if not content_node: return 0
			return -int(pos.y)
		
		_:
			return null

func _set(property: StringName, value: Variant) -> bool:
	match property:
		"scroll_horizontal":
			if not content_node:
				scroll_horizontal = 0
				return true
			
			if _initializing_margins: return true

			scroll_horizontal = value
			scrollbar_animator.kill_scroll_x_tween()
			velocity.x = 0.0
			var spare_size_x: float = ScrollLayout.get_spare_size_x(self, content_margins)
			pos.x = clampf(
				-value as float,
				-ScrollLayout.get_child_size_x_diff(content_node, spare_size_x, true),
				0.0
			)

			set_process(true) 
			return true
		
		"scroll_vertical":
			if not content_node:
				scroll_vertical = 0
				return true
			
			if _initializing_margins: return true

			scroll_vertical = value
			scrollbar_animator.kill_scroll_y_tween()
			velocity.y = 0.0
			var spare_size_y: float = ScrollLayout.get_spare_size_y(self, content_margins)
			pos.y = clampf(
				-value as float,
				-ScrollLayout.get_child_size_y_diff(content_node, spare_size_y, true),
				0.0
			)

			set_process(true)
			return true
		_:
			return false

func scroll(vertical: bool, axis_velocity: float, axis_pos: float, delta: float) -> void:


	if is_zero_approx(delta):
		if vertical:
			velocity.y = axis_velocity
			pos.y = axis_pos
			if content_node:
				content_node.position.y = _base_offset.y + axis_pos
			if get_v_scroll_bar(): get_v_scroll_bar().set_value_no_signal(-axis_pos)
		else:
			velocity.x = axis_velocity
			pos.x = axis_pos
			if content_node:
				content_node.position.x = _base_offset.x + axis_pos
			if get_h_scroll_bar(): get_h_scroll_bar().set_value_no_signal(-axis_pos)
		return


	if vertical:
		if not should_scroll_vertical(): 

			if auto_allow_scroll and pos.y != 0 and content_node:
				var spare = ScrollLayout.get_spare_size_y(self, content_margins)
				var diff = ScrollLayout.get_child_size_y_diff(content_node, spare, false)
				if diff <= 0:
					velocity.y = 0.0
					pos.y = 0.0
					content_node.position.y = _base_offset.y + pos.y
			return
	
	else:
		if not should_scroll_horizontal(): 

			if auto_allow_scroll and pos.x != 0 and content_node:
				var spare = ScrollLayout.get_spare_size_x(self, content_margins)
				var diff = ScrollLayout.get_child_size_x_diff(content_node, spare, false)
				if diff <= 0:
					velocity.x = 0.0
					pos.x = 0.0
					content_node.position.x = _base_offset.x + pos.x
			return
	
	if not scroll_damper: return

	if not input_handler.content_dragging:
		axis_velocity = handle_overdrag(vertical, axis_velocity, axis_pos, delta)

		var slide_result: Array = scroll_damper.slide(axis_velocity, delta)
		axis_velocity = slide_result[0]
		axis_pos += slide_result[1]

		var snap_result: Array = snap(vertical, axis_velocity, axis_pos)
		axis_velocity = snap_result[0]
		axis_pos = snap_result[1]
	else:


		if input_handler.content_dragging_moved:
			input_handler.content_dragging_moved = false
		else:
			axis_velocity = 0.0


	if handle_scrollbar_drag():	return
	
	if vertical:
		if not allow_overdragging:

			var spare_size_y: float = ScrollLayout.get_spare_size_y(self, content_margins)
			var size_diff_y: float = ScrollLayout.get_child_size_y_diff(content_node, spare_size_y, true)

			if ScrollLayout.is_outside_top_boundary(axis_pos):
				axis_pos = 0.0
				axis_velocity = 0.0
			
			elif ScrollLayout.is_outside_bottom_boundary(axis_pos, size_diff_y):
				axis_pos = -size_diff_y
				axis_velocity = 0.0
		content_node.position.y = _base_offset.y + axis_pos
		pos.y = axis_pos
		velocity.y = axis_velocity
	
	else:
		if not allow_overdragging:

			var spare_size_x: float = ScrollLayout.get_spare_size_x(self, content_margins)
			var size_diff_x: float = ScrollLayout.get_child_size_x_diff(content_node, spare_size_x, true)

			if ScrollLayout.is_outside_left_boundary(axis_pos):
				axis_pos = 0.0
				axis_velocity = 0.0
			
			elif ScrollLayout.is_outside_right_boundary(axis_pos, size_diff_x):
				axis_pos = -size_diff_x
				axis_velocity = 0.0
			
		content_node.position.x = _base_offset.x + axis_pos
		pos.x = axis_pos
		velocity.x = axis_velocity

func handle_overdrag(vertical: bool, axis_velocity: float, axis_pos: float, delta: float) -> float:
	if not scroll_damper: return 0.0
	
	var spare_size: Vector2 = ScrollLayout.get_spare_size(self, content_margins)
	var size_diff: float = ScrollLayout.get_child_size_y_diff(content_node, spare_size.y, true) if vertical \
		else ScrollLayout.get_child_size_x_diff(content_node, spare_size.x, true)
	
	return ScrollPhysics.apply_overdrag(scroll_damper, axis_pos, axis_velocity, size_diff, delta)

func snap(vertical: bool, axis_velocity: float, axis_pos: float) -> Array:
	var spare_size: Vector2 = ScrollLayout.get_spare_size(self, content_margins)
	var size_diff: float = ScrollLayout.get_child_size_y_diff(content_node, spare_size.y, true) if vertical \
		else ScrollLayout.get_child_size_x_diff(content_node, spare_size.x, true)
	
	return ScrollPhysics.apply_snap(axis_velocity, axis_pos, size_diff, just_snap_under)

func handle_scrollbar_drag() -> bool:
	if input_handler.h_scrollbar_dragging:
		velocity.x = 0.0
		pos.x = -get_h_scroll_bar().value
		content_node.position.x = _base_offset.x + pos.x
		return true
	
	if input_handler.v_scrollbar_dragging:
		velocity.y = 0.0
		pos.y = -get_v_scroll_bar().value
		content_node.position.y = _base_offset.y + pos.y
		return true
	
	return false

func handle_content_dragging() -> void:
	if not dragging_scroll_damper: return
	
	input_handler.content_dragging_moved = true
	
	if should_scroll_vertical():
		var y_pos: float = ScrollPhysics.calculate_drag_position(
			input_handler.drag_temp_data[6],
			input_handler.drag_temp_data[7],
			input_handler.drag_temp_data[1],
			input_handler.drag_temp_data[3],
			dragging_scroll_damper._attract_factor
		)
		velocity.y = (y_pos - pos.y) / get_process_delta_time()
		pos.y = y_pos
		content_node.position.y = _base_offset.y + y_pos
	
	if should_scroll_horizontal():
		var x_pos: float = ScrollPhysics.calculate_drag_position(
			input_handler.drag_temp_data[4],
			input_handler.drag_temp_data[5],
			input_handler.drag_temp_data[0],
			input_handler.drag_temp_data[2],
			dragging_scroll_damper._attract_factor
		)
		velocity.x = (x_pos - pos.x) / get_process_delta_time()
		pos.x = x_pos
		content_node.position.x = _base_offset.x + x_pos

func update_is_scrolling() -> void:
	if(
		(input_handler.content_dragging and not input_handler.is_in_deadzone)
		or input_handler.any_scrollbar_dragging()
		or velocity != Vector2.ZERO
		or scrollbar_animator.has_active_scroll_tween()
	):
		is_scrolling = true
	
	else:
		is_scrolling = false

func update_scrollbars() -> void:

	if get_v_scroll_bar().value != -pos.y:
		get_v_scroll_bar().set_value_no_signal(-pos.y)
		get_v_scroll_bar().queue_redraw()
	

	if get_h_scroll_bar().value != -pos.x:
		get_h_scroll_bar().set_value_no_signal(-pos.x)
		get_h_scroll_bar().queue_redraw()
	

	if hide_scrollbar_over_time and (is_scrolling or input_handler.mouse_on_scrollbar):
		scrollbar_animator.show_scrollbars()

func scroll_x_to(x_pos: float, duration := 0.5) -> void:
	if not should_scroll_horizontal(): return
	if input_handler.content_dragging: return
	_scroll_x_to_internal(x_pos, duration)

func _scroll_x_to_internal(x_pos: float, duration := 0.5) -> void:
	if not content_node: return
	if not allow_horizontal_scroll: return
	
	set_process(true)
	velocity.x = 0.0
	var spare_size_x: float = ScrollLayout.get_spare_size_x(self, content_margins)
	var size_x_diff: float = ScrollLayout.get_child_size_x_diff(content_node, spare_size_x, true)
	x_pos = clampf(x_pos, -size_x_diff, 0.0)
	scrollbar_animator.kill_scroll_x_tween()
	scrollbar_animator.scroll_x_to(x_pos, duration)

func scroll_y_to(y_pos: float, duration := 0.5) -> void:
	if not should_scroll_vertical(): return
	if input_handler.content_dragging: return
	_scroll_y_to_internal(y_pos, duration)

func _scroll_y_to_internal(y_pos: float, duration := 0.5) -> void:
	if not content_node: return
	if not allow_vertical_scroll: return

	set_process(true)
	velocity.y = 0.0
	var spare_size_y: float = ScrollLayout.get_spare_size_y(self, content_margins)
	var size_y_diff: float = ScrollLayout.get_child_size_y_diff(content_node, spare_size_y, true)
	y_pos = clampf(y_pos, -size_y_diff, 0.0)
	scrollbar_animator.kill_scroll_y_tween()
	scrollbar_animator.scroll_y_to(y_pos, duration)

func scroll_page_up(duration := 0.5) -> void:
	var destination: float = pos.y + ScrollLayout.get_spare_size_y(self, content_margins)
	scroll_y_to(destination, duration)

func scroll_page_down(duration := 0.5) -> void:
	var destination: float = pos.y - ScrollLayout.get_spare_size_y(self, content_margins)
	scroll_y_to(destination, duration)

func scroll_page_left(duration := 0.5) -> void:
	var destination: float = pos.x + ScrollLayout.get_spare_size_x(self, content_margins)
	scroll_x_to(destination, duration)

func scroll_page_right(duration := 0.5) -> void:
	var destination: float = pos.x - ScrollLayout.get_spare_size_x(self, content_margins)
	scroll_x_to(destination, duration)

func scroll_vertically(amount: float) -> void:
	velocity.y -= amount
	set_process(true)

func scroll_horizontally(amount: float) -> void:
	velocity.x -= amount
	set_process(true)

func scroll_to_top(duration := 0.5) -> void:
	scroll_y_to(0.0, duration)

func scroll_to_bottom(duration := 0.5) -> void:
	var spare_size_y: float = ScrollLayout.get_spare_size_y(self, content_margins)
	scroll_y_to(spare_size_y - content_node.size.y, duration)

func scroll_to_left(duration := 0.5) -> void:
	scroll_x_to(0.0, duration)

func scroll_to_right(duration := 0.5) -> void:
	var spare_size_x: float = ScrollLayout.get_spare_size_x(self, content_margins)
	scroll_x_to(spare_size_x - content_node.size.x, duration)

func reset_scroll() -> void:
	velocity = Vector2.ZERO
	pos = Vector2.ZERO
	scrollbar_animator.kill_scroll_tweens()
	if content_node:


		content_node.position = _base_offset
	

	if get_v_scroll_bar(): get_v_scroll_bar().value = 0
	if get_h_scroll_bar(): get_h_scroll_bar().value = 0

func should_scroll_vertical() -> bool:
	var spare_size_y: float = ScrollLayout.get_spare_size_y(self, content_margins)
	var child_size_diff: float = ScrollLayout.get_child_size_y_diff(content_node, spare_size_y, false)
	var disable_scroll: bool = (not allow_vertical_scroll) \
		or (auto_allow_scroll and child_size_diff <= 0) \
		or not scroll_damper
	
	if disable_scroll:
		velocity.y = 0.0
		return pos.y != 0
	
	else:
		return true

func should_scroll_horizontal() -> bool:
	var spare_size_x: float = ScrollLayout.get_spare_size_x(self, content_margins)
	var child_size_diff: float = ScrollLayout.get_child_size_x_diff(content_node, spare_size_x, false)
	var disable_scroll: bool = (not allow_horizontal_scroll) \
		or (auto_allow_scroll and child_size_diff <= 0) \
		or not scroll_damper
	
	if disable_scroll:
		velocity.x = 0.0
		return pos.x != 0
	
	else:
		return true

func ensure_control_visible(control: Control) -> void:
	ensure_control_visible_smooth(control)

func ensure_control_visible_smooth(control: Control) -> void:
	if not content_node: return
	if not content_node.is_ancestor_of(control): return
	if not scroll_damper: return

	following_focus = true
	

	var current_size := size
	if current_size.x <= 0 or current_size.y <= 0:
		_pending_ensure_control = control
		if not resized.is_connected(_on_resized_for_ensure_continuous):
			resized.connect(_on_resized_for_ensure_continuous)
		return
	

	_execute_ensure_control_visible(control, false)
	

	_pending_ensure_control = control
	_last_ensure_size = current_size
	if not resized.is_connected(_on_resized_for_ensure_continuous):
		resized.connect(_on_resized_for_ensure_continuous)
	

	_start_stability_timer()

func _start_stability_timer() -> void:
	if not _ensure_stability_timer:
		_ensure_stability_timer = Timer.new()
		_ensure_stability_timer.one_shot = true
		_ensure_stability_timer.timeout.connect(_on_stability_timeout)
		add_child(_ensure_stability_timer)
	_ensure_stability_timer.start(0.6)

func _on_stability_timeout() -> void:
	if resized.is_connected(_on_resized_for_ensure_continuous):
		resized.disconnect(_on_resized_for_ensure_continuous)
	_pending_ensure_control = null
	_last_ensure_size = Vector2.ZERO

func _on_resized_for_ensure_continuous() -> void:
	var current_size: Vector2 = size
	if current_size.x <= 0 or current_size.y <= 0: return
	
	if _pending_ensure_control and is_instance_valid(_pending_ensure_control):
		_execute_ensure_control_visible(_pending_ensure_control, true)
		_last_ensure_size = current_size
		_start_stability_timer()

func _execute_ensure_control_visible(control: Control, instant: bool) -> void:
	var control_rect: Rect2 = control.get_global_rect()
	var content_rect: Rect2 = content_node.get_global_rect()
	
	var control_in_content: Vector2 = control_rect.position - content_rect.position
	var visible_size := Vector2(
		ScrollLayout.get_spare_size_x(self, content_margins),
		ScrollLayout.get_spare_size_y(self, content_margins)
	)
	
	set_process(true)
	
	var target_x: float = pos.x
	var target_y: float = pos.y
	

	var control_top_in_view: float = control_in_content.y + pos.y
	var control_bottom_in_view: float = control_top_in_view + control_rect.size.y
	var control_left_in_view: float = control_in_content.x + pos.x
	var control_right_in_view: float = control_left_in_view + control_rect.size.x
	

	if control_left_in_view < follow_focus_margin:
		target_x = -(control_in_content.x - follow_focus_margin)
	elif control_right_in_view > visible_size.x - follow_focus_margin:
		target_x = -(control_in_content.x + control_rect.size.x - visible_size.x + follow_focus_margin)
	

	if control_top_in_view < follow_focus_margin:
		target_y = -(control_in_content.y - follow_focus_margin)
	elif control_bottom_in_view > visible_size.y - follow_focus_margin:
		target_y = -(control_in_content.y + control_rect.size.y - visible_size.y + follow_focus_margin)
	

	var spare_size_x: float = ScrollLayout.get_spare_size_x(self, content_margins)
	var spare_size_y: float = ScrollLayout.get_spare_size_y(self, content_margins)
	var size_x_diff: float = ScrollLayout.get_child_size_x_diff(content_node, spare_size_x, true)
	var size_y_diff: float = ScrollLayout.get_child_size_y_diff(content_node, spare_size_y, true)
	
	target_x = clampf(target_x, -size_x_diff, 0.0)
	target_y = clampf(target_y, -size_y_diff, 0.0)
	

	if instant:
		scrollbar_animator.kill_scroll_tweens()
		pos.x = target_x
		pos.y = target_y
		content_node.position.x = _base_offset.x + target_x
		content_node.position.y = _base_offset.y + target_y
	

	else:
		if target_x != pos.x:
			_scroll_x_to_internal(target_x)
		if target_y != pos.y:
			_scroll_y_to_internal(target_y)

