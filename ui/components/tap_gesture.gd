class_name TapGesture extends RefCounted

signal pressed
signal released
signal tapped

const CANCEL_DISTANCE := 32.0
const LONG_PRESS_TIME := 0.5

static var touch_input_seen: bool = false

var held: bool = false
var long_press: Callable

var _control: Control
var _dragged: float = 0.0
var _press_point: Vector2 = Vector2.ZERO
var _pointer_input: bool = false
var _press_id: int = 0

func _init(control: Control) -> void:
	_control = control


func feed(event: InputEvent) -> bool:
	if event is InputEventScreenTouch:
		touch_input_seen = true
		_pointer_input = true
		if event.canceled:
			if held:
				held = false
				released.emit()
			return false
		return _gesture(event.is_pressed(), _control.get_global_transform() * event.position)

	if event is InputEventScreenDrag or event is InputEventMouseMotion:
		if held:
			_dragged += event.relative.length()
			if _dragged > CANCEL_DISTANCE:
				held = false
				released.emit()
		return false

	if event is InputEventMouseButton:
		if (event as InputEventMouseButton).button_index != MOUSE_BUTTON_LEFT:
			return false
		if touch_input_seen or event.device == InputEvent.DEVICE_ID_EMULATION:
			return true
		_pointer_input = true
		_gesture(event.is_pressed(), _control.get_global_transform() * event.position)
		return true

	if event.is_action("ui_accept"):
		_pointer_input = false
		_gesture(event.is_pressed(), _press_point)
		return true

	return false

func cancel() -> void:
	if held:
		held = false
		released.emit()

func _gesture(is_press: bool, point: Vector2) -> bool:
	if is_press:
		if held:
			return false
		held = true
		_dragged = 0.0
		_press_point = point
		pressed.emit()
		_press_id += 1
		var press_id := _press_id
		if long_press.is_valid() and _control.is_inside_tree():
			_control.get_tree().create_timer(LONG_PRESS_TIME).timeout.connect(func():
				if press_id == _press_id and held and _dragged <= CANCEL_DISTANCE and long_press.call():
					held = false
					released.emit())
		return false

	if not held:
		return false
	var was_tap := point.distance_to(_press_point) <= CANCEL_DISTANCE
	held = false
	released.emit()
	if not was_tap:
		return false
	var handler: Callable = _control.get_meta(VirtualContainer.TAP_META, Callable())
	if _pointer_input and handler.is_valid() and handler.call():
		return true
	tapped.emit()
	return true
