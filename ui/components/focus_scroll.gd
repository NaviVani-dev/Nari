@tool
class_name FocusScroll extends SmoothScrollContainer

signal item_focused(index: int, item: Control)
signal item_moved(from: int, to: int)

const UNFOCUSED_OPACITY: = 0.5
const DRAG_EDGE: = 180.0
const DRAG_SCROLL_SPEED: = 1400.0
const DRAG_FOLLOW: = 18.0
const DRAG_HOLD_TIME: = 1.0

@export var keep_focus_visible: bool = true

@export_range(0.0, 1.0, 0.05) var release_visibility: float = 0.5


@export_range(0.0, 1.0, 0.05) var adopt_visibility: float = 0.75


@export var overscan: int = 3

@export_group("Interaction")
@export var distance_unfocused: bool = false:
	set(value):
		distance_unfocused = value
		_update_effects()

@export_group("Padding")
@export var padding_left: int = 0:
	set(value):
		padding_left = value
		_apply_padding()
@export var padding_top: int = 0:
	set(value):
		padding_top = value
		_apply_padding()
@export var padding_right: int = 0:
	set(value):
		padding_right = value
		_apply_padding()
@export var padding_bottom: int = 0:
	set(value):
		padding_bottom = value
		_apply_padding()

const ENTRANCE_TIME: = 0.25
const ENTRANCE_STAGGER: = 0.035

var _data: Array = []
var _builder: Callable
var _binder: Callable
var _live: Dictionary = {}
var _pool: Array[Control] = []
var _window: = Vector2i(0, -1)
var _offset: float = INF
var _entrance: Tween
var _pending: bool = false
var _generation: int = 0
var hint_text: Callable
var shape_of: Callable
var max_width: float = 0.0:
	set(value):
		max_width = value
		_apply_padding()
var _hint: NariPanelContainer
var _hint_label: NariLabel
var _selected: int = -1
var _drag_point: float = 0.0
var _drag_grab: float = 0.0
var _drag_follow: bool = false

var container: VirtualContainer:
	get: return content_node as VirtualContainer

func _ready() -> void :
	super._ready()
	_apply_padding()
	if container and not Engine.is_editor_hint():
		InputGlyphs.mode_changed.connect(_update_effects.unbind(1))
	resized.connect(_refresh)
	resized.connect(func():
		if max_width > 0.0:
			_apply_padding())

func _process(delta: float) -> void :
	super._process(delta)
	_refresh()
	_keep_focus_in_view()
	_update_hint()
	if container and container.drag_from >= 0:
		_update_drag(delta)
		set_process(true)

func add_drag_handle(handle: Control, item: Control) -> void :
	handle.mouse_filter = Control.MOUSE_FILTER_PASS
	handle.set_meta("_smooth_scroll_default_mouse_filter_set", true)
	var hold: = {"id": 0, "active": false, "origin": Vector2.ZERO, "point": Vector2.ZERO}
	handle.gui_input.connect( func(event: InputEvent):
		var pressing: bool = event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT)
		var moving: bool = event is InputEventScreenDrag or event is InputEventMouseMotion
		if not pressing and not moving:
			return
		var point: Vector2 = get_global_transform().affine_inverse() * (handle.get_global_transform() * event.position)
		hold.point = point
		if container.drag_from >= 0:
			if moving:
				handle.accept_event()
				_drag_point = point.y
			elif not event.pressed:
				_end_drag()
			return
		if pressing and event.pressed:
			hold.id += 1
			hold.active = true
			hold.origin = point
			var press_id: int = hold.id
			get_tree().create_timer(DRAG_HOLD_TIME).timeout.connect( func():
				if hold.active and hold.id == press_id and is_instance_valid(item) and item.is_inside_tree():
					hold.active = false
					_begin_drag(item, hold.point.y))
		elif pressing:
			hold.active = false
		elif hold.active and (point.distance_to(hold.origin) > TapGesture.CANCEL_DISTANCE or (input_handler.content_dragging and not input_handler.is_in_deadzone)):
			hold.active = false)

func _begin_drag(item: Control, point: float) -> void :
	var index: = _row_of(item)
	if index < 0 or container.drag_from >= 0:
		return
	if item.has_method("cancel_press"):
		item.cancel_press()
	_drag_follow = follow_focus
	follow_focus = false
	container.drag_from = index
	container.drag_to = index
	_drag_point = point
	_drag_grab = point - container.position.y - container.rect_of(index).position.y
	container.drag_y = container.rect_of(index).position.y
	_live[index].z_index = 1
	set_process(true)

func _update_drag(delta: float) -> void :
	var edge: = 0.0
	if _drag_point < DRAG_EDGE:
		edge = -(1.0 - maxf(_drag_point, 0.0) / DRAG_EDGE)
	elif _drag_point > size.y - DRAG_EDGE:
		edge = minf((_drag_point - size.y + DRAG_EDGE) / DRAG_EDGE, 1.0)
	if edge != 0.0:
		self.scroll_vertical = maxi(self.scroll_vertical + roundi(edge * DRAG_SCROLL_SPEED * delta), 0)
	var last: = container.rect_of(container.count - 1).position.y
	container.drag_y = clampf(_drag_point - _drag_grab - container.position.y, 0.0, last)
	container.drag_to = clampi(roundi(container.drag_y / container.row_height()), 0, container.count - 1)
	var weight: = 1.0 - exp(-DRAG_FOLLOW * delta)
	for index in _live:
		var row: Control = _live[index]
		var target: = container.rect_of(container.display_slot(index))
		row.position.x = target.position.x + float(row.get_meta(VirtualContainer.ENTRANCE_META, 0.0))
		row.position.y = container.drag_y if index == container.drag_from else lerpf(row.position.y, target.position.y, weight)

func _end_drag() -> void :
	var from: = container.drag_from
	if from < 0:
		return
	var to: = container.drag_to
	container.drag_from = -1
	container.drag_to = -1
	follow_focus = _drag_follow
	if _live.has(from):
		_live[from].z_index = 0
	if from == to:
		container.queue_sort()
		return
	_data.insert(to, _data.pop_at(from))
	_clear()
	_refresh()
	item_moved.emit(from, to)

func _update_hint() -> void :
	var bar: = get_v_scroll_bar()
	var dragging: = hint_text.is_valid() and input_handler != null and input_handler.v_scrollbar_dragging and not _data.is_empty()
	if not dragging:
		if _hint:
			_hint.hide()
		return
	if not _hint:
		_hint = NariPanelContainer.new()
		_hint.top_level = true
		_hint.corner_radius = 48.0
		_hint.custom_minimum_size = Vector2(144, 144)
		_hint_label = NariLabel.new()
		_hint_label.color = ThemeEngine.Colors.PanelFg
		_hint_label.font_size = 80
		_hint_label.weight = 700
		_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_hint.add_child(_hint_label)
		for control in [_hint, _hint_label]:
			control.mouse_filter = Control.MOUSE_FILTER_IGNORE
			control.set_meta("_smooth_scroll_default_mouse_filter_set", true)
		add_child(_hint)
	var index: = clampi(container.window( - container.position.y, size.y, 0).x, 0, _data.size() - 1)
	_hint_label.text = str(hint_text.call(_data[index]))
	var along: = clampf(bar.value / maxf(bar.max_value - bar.page, 1.0), 0.0, 1.0)
	var edge: Control = get_meta("edge_scrollbar", bar)
	_hint.global_position = Vector2(edge.global_position.x - _hint.size.x, bar.global_position.y + along * maxf(bar.size.y - _hint.size.y, 0.0))
	_hint.show()

func _on_focus_changed(control: Control) -> void :
	super._on_focus_changed(control)
	_offset = INF
	if control and is_ancestor_of(control):
		_commit_focus_deferred.call_deferred(control)

func _commit_focus_deferred(control: Control) -> void :
	if not is_instance_valid(control) or not is_ancestor_of(control) or not control.has_focus():
		return
	if control.has_method("is_held") and control.is_held():
		return
	_commit_focus(control)

func _handle_item_tap(item: Control) -> bool:
	_commit_focus(item, false)
	return false

func _commit_focus(control: Control, follow: bool = true) -> void :
	var index: = _row_of(control)
	if index < 0 or index == _selected:
		return
	_selected = index
	var previous: = follow_focus
	follow_focus = follow_focus and follow
	control.grab_focus()
	follow_focus = previous
	_update_effects()
	item_focused.emit(index, get_item(index))

func _apply_padding() -> void :
	var extra: = maxf(size.x - max_width, 0.0) if max_width > 0.0 else 0.0
	var style: = StyleBoxEmpty.new()
	style.content_margin_left = padding_left
	style.content_margin_top = padding_top
	style.content_margin_right = padding_right + extra
	style.content_margin_bottom = padding_bottom
	add_theme_stylebox_override("panel", style)
	add_theme_constant_override("scrollbar_h_separation", 0)

func set_items(list: Array, builder: Callable, binder: = Callable(), refresh: = false) -> void :
	if not container:
		return
	_builder = builder
	_binder = binder
	_data = list.duplicate()
	if refresh and binder.is_valid():
		_rebind()
	else:
		_selected = -1
		_clear()
	container.drag_from = -1
	container.count = _data.size()
	container.cell_height = _measure()
	if refresh:
		_refresh()
		_update_effects()
		return
	self.scroll_vertical = 0
	_refresh()
	play_entrance()

func focus_item(index: int) -> void :
	if not container or index < 0 or index >= _data.size():
		return
	await get_tree().process_frame
	if not is_inside_tree():
		return
	if _visibility(index) < adopt_visibility:
		self.scroll_vertical = int(container.rect_of(index).position.y)
	_refresh()
	await get_tree().process_frame

	if not is_inside_tree():
		return
	var row: = get_item(index)
	if row and row.is_inside_tree() and row.focus_mode != Control.FOCUS_NONE:
		row.grab_focus()


func get_selected() -> int:
	return _selected

func get_item(index: int) -> Control:
	var row: Control = _live.get(index)
	return row.get_meta(VirtualContainer.ITEM_META, row) if row else null

func _clear() -> void :
	_stop_entrance()
	for row in _live.values():
		row.queue_free()
	for row in _pool:
		row.queue_free()
	_live.clear()
	_pool.clear()
	_window = Vector2i(0, -1)


func _rebind() -> void:
	_stop_entrance()
	if _selected >= _data.size():
		_selected = -1
	for index in _live.keys():
		if index < _data.size():
			_binder.call(get_item(index), _data[index])
		else:
			_recycle(index)
	_window = Vector2i(0, -1)

func _measure() -> float:
	var headers: = container.headers
	container.header_height = _sample_height(headers[0]) if not headers.is_empty() and headers[0] < _data.size() else 0.0
	var cell: = container.header_height
	for index in _data.size():
		if not headers.has(index):
			cell = _sample_height(index)
			break
	container.row_heights = _shape_heights(headers)
	return cell

func _shape_heights(headers: PackedInt32Array) -> Dictionary:
	var heights: = {}
	if not shape_of.is_valid() or container.columns != 1:
		return heights
	var common: Variant = null
	var sampled: = {}
	for index in _data.size():
		if headers.has(index):
			continue
		var shape: Variant = shape_of.call(_data[index])
		if common == null:
			common = shape
		elif shape != common:
			if not sampled.has(shape):
				sampled[shape] = _sample_height(index)
			heights[index] = sampled[shape]
	return heights

func _sample_height(index: int) -> float:
	var sample: Control = _builder.call(_data[index])
	sample.modulate.a = 0.0
	container.add_child(sample)
	var height: = sample.get_combined_minimum_size().y
	container.remove_child(sample)
	sample.queue_free()
	return height

func _refresh() -> void :
	if not container or _data.is_empty():
		return
	var window: = container.window( - container.position.y, size.y, overscan)
	if window == _window:
		return
	_stop_entrance()
	_window = window
	var focused: = _focus_row()
	for index in _live.keys():
		if (index < window.x or index > window.y) and index != focused and index != container.drag_from:
			_recycle(index)
	for index in range(window.x, window.y + 1):
		if not _live.has(index):
			_live[index] = _spawn(index)
	container.queue_sort()
	_rows_changed()

func _rows_changed() -> void :
	_update_effects()

func _update_effects() -> void :
	if not container:
		return
	var animating: = entrance_running()
	var pending: = entrance_pending()
	for child in container.get_children():
		var row: = child as Control
		if not row or not row.visible:
			continue
		if pending:
			_apply_effect(row, 0.0)
		else:
			_apply_effect(row, row.modulate.a if animating else _row_opacity(row))

func _row_opacity(row: Control) -> float:
	var unfocused: = _selected >= 0 and container.index_of(row) != _selected
	return UNFOCUSED_OPACITY if distance_unfocused and unfocused and InputGlyphs.navigating() else 1.0

func _fade_in(row: Control, progress: float) -> void :
	if is_instance_valid(row):
		_apply_effect(row, progress * _row_opacity(row))

func _apply_effect(row: Control, opacity: float) -> void :
	if not is_instance_valid(row):
		return
	if row.has_method("set_depth"):
		row.set_depth(0.0)
	row.modulate.a = opacity

func entrance_running() -> bool:
	return _entrance != null and _entrance.is_valid()

func entrance_pending() -> bool:
	return _pending

func play_entrance() -> void :
	_stop_entrance()
	_pending = false
	if Engine.is_editor_hint() or not is_inside_tree() or not Themes.enabled("motion", "entrance"):
		return
	_generation += 1
	var generation: = _generation
	_pending = true
	_rows_changed()
	for wait in 12:
		await get_tree().process_frame
		if generation != _generation:
			return
		if not is_inside_tree():
			_pending = false
			return
		if size.y > 0.0 and container.cell_height > 0.0 and not _live.is_empty():
			break
	if size.y <= 0.0 or _live.is_empty():
		_abort_entrance()
		return
	await get_tree().process_frame
	if generation != _generation:
		return
	if not is_inside_tree() or _live.is_empty():
		_abort_entrance()
		return
	var tween: = create_tween().set_parallel(true)
	var staged: = false
	var order: = _live.keys()
	order.sort()
	var onscreen: = container.window( - container.position.y, size.y, 0)
	var step: = 0
	for index in order:
		if index < onscreen.x or index > onscreen.y:
			continue
		_stage_entrance(_live[index], tween, float(step) * ENTRANCE_STAGGER)
		step += 1
		staged = true
	if not staged:
		tween.kill()
		_abort_entrance()
		return
	tween.chain().tween_callback(func():
		_entrance = null
		_rows_changed())
	_pending = false
	_entrance = tween

func _abort_entrance() -> void :
	_pending = false
	_rows_changed()

func _stop_entrance() -> void :
	if not _entrance:
		return
	if _entrance.is_valid():
		_entrance.kill()
	_entrance = null
	for row in _live.values():
		if is_instance_valid(row):
			_settle_entrance(row)

func _stage_entrance(_row: Control, _tween: Tween, _delay: float) -> void :
	pass

func _settle_entrance(_row: Control) -> void :
	pass

func _spawn(index: int) -> Control:
	var row: Control
	if _binder.is_valid() and not _pool.is_empty():
		row = _pool.pop_back()
		_binder.call(row.get_meta(VirtualContainer.ITEM_META, row), _data[index])
		row.show()
	else:
		row = _builder.call(_data[index])
		var item: Control = row.get_meta(VirtualContainer.ITEM_META, row)
		item.set_meta(VirtualContainer.TAP_META, _handle_item_tap.bind(item))
		container.add_child(row)
	row.set_meta(VirtualContainer.INDEX_META, index)
	row.set_meta(VirtualContainer.ENTRANCE_META, 0.0)
	return row

func _recycle(index: int) -> void :
	var row: Control = _live[index]
	_live.erase(index)
	if not _binder.is_valid():
		_stop_entrance()
	if _binder.is_valid():
		row.hide()
		_pool.append(row)
	else:
		container.remove_child(row)
		row.queue_free()

func _keep_focus_in_view() -> void :
	if not keep_focus_visible or not container or Engine.is_editor_hint() or container.drag_from >= 0:
		return
	if is_equal_approx(container.position.y, _offset):
		return
	_offset = container.position.y

	if following_focus:
		return

	var focused: = _focus_row()
	if focused < 0 or _visibility(focused) >= release_visibility:
		return

	var step: = 1 if _top_of(focused) < 0.0 else -1
	var index: = focused + step
	while index >= _window.x and index <= _window.y:
		var row: Control = _live.get(index)
		if row:
			var target: Control = row.get_meta(VirtualContainer.FOCUS_TARGET_META, row)
			if target and target.focus_mode != Control.FOCUS_NONE and _visibility(index) >= adopt_visibility:

				var follow: = follow_focus
				follow_focus = false
				target.grab_focus()
				follow_focus = follow
				return
		index += step

func _focus_row() -> int:
	if not container or not is_inside_tree():
		return -1
	var control: = get_viewport().gui_get_focus_owner()
	if not control or not is_ancestor_of(control):
		return -1
	return _row_of(control)

func _row_of(control: Node) -> int:
	var node: Node = control
	while node and node.get_parent() != container:
		node = node.get_parent()
	return container.index_of(node) if node else -1

func _top_of(index: int) -> float:
	return container.position.y + container.rect_of(index).position.y

func _visibility(index: int) -> float:
	var height: = container.rect_of(index).size.y
	if height <= 0.0:
		return 0.0
	var top: = _top_of(index)
	return clampf((minf(top + height, size.y) - maxf(top, 0.0)) / height, 0.0, 1.0)
