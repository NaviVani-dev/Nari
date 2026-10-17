class_name SwipeDismiss extends Node

const START_DISTANCE := 40.0
const VERTICAL_BIAS := 1.5
const CLOSE_SHARE := 0.22
const CLOSE_SPEED := 1600.0
const SETTLE_TIME := 0.28
const CLOSE_TIME := 0.2
const BLOCKERS := "swipe_blockers"

var area: Control
var targets: Array[Control] = []
var allowed: Callable
var _pressed := false
var _dragging := false
var _origin := Vector2.ZERO
var _offset := 0.0
var _speed := 0.0
var _stamp := 0
var _rests: Array[float] = []
var _tween: Tween

static func attach(touch_area: Control, moved: Array[Control], can_swipe: Callable) -> SwipeDismiss:
	var swipe := SwipeDismiss.new()
	swipe.area = touch_area
	swipe.targets = moved
	swipe.allowed = can_swipe
	touch_area.add_child(swipe)
	return swipe

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.index == 0:
			_press(event.is_pressed() and not event.canceled, event.position)
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and not TapGesture.touch_input_seen and event.device != InputEvent.DEVICE_ID_EMULATION:
			_press(event.is_pressed(), event.position)
	elif event is InputEventScreenDrag:
		if event.index == 0:
			_move(event.position)
	elif event is InputEventMouseMotion:
		if not TapGesture.touch_input_seen and event.device != InputEvent.DEVICE_ID_EMULATION:
			_move(event.position)

func _press(down: bool, point: Vector2) -> void:
	if down:
		_pressed = area.is_visible_in_tree() and area.get_global_rect().has_point(point) and not _blocked(point) and allowed.call()
		_dragging = false
		_origin = point
		return
	var was_dragging := _dragging
	_pressed = false
	_dragging = false
	if not was_dragging:
		return
	get_viewport().set_input_as_handled()
	if _offset > area.size.y * CLOSE_SHARE or _speed > CLOSE_SPEED:
		_close()
	else:
		_settle()

func _blocked(point: Vector2) -> bool:
	for blocker: Control in get_tree().get_nodes_in_group(BLOCKERS):
		if blocker.is_visible_in_tree() and blocker.get_global_rect().has_point(point):
			return true
	return false

func _move(point: Vector2) -> void:
	if not _pressed:
		return
	var delta := point - _origin
	if not _dragging:
		if delta.y < START_DISTANCE or delta.y < absf(delta.x) * VERTICAL_BIAS or not allowed.call():
			if delta.length() > START_DISTANCE:
				_pressed = false
			return
		_dragging = true
		_origin = point
		_offset = 0.0
		_speed = 0.0
		_stamp = Time.get_ticks_usec()
		if _tween:
			_tween.kill()
		_rests.clear()
		for target in targets:
			_rests.append(target.position.y)
	get_viewport().set_input_as_handled()
	var now := Time.get_ticks_usec()
	var offset := maxf(point.y - _origin.y, 0.0)
	_speed = (offset - _offset) / maxf((now - _stamp) / 1000000.0, 0.001)
	_stamp = now
	_offset = offset
	_place(offset)

func _place(offset: float) -> void:
	for index in targets.size():
		if is_instance_valid(targets[index]):
			targets[index].position.y = _rests[index] + offset

func _settle() -> void:
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_method(_place, _offset, 0.0, SETTLE_TIME)

func _close() -> void:
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_method(_place, _offset, area.size.y, CLOSE_TIME)
	_tween.tween_callback(func():
		if not Main.go_back():
			Main.go_home())
