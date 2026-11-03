class_name EdgeSwipe extends CanvasLayer

const EDGE_SHARE := 0.04
const START_DISTANCE := 24.0
const HORIZONTAL_BIAS := 1.5
const BACK_SHARE := 0.16
const BACK_SPEED := 1400.0
const ARROW_SIZE := 96.0
const SETTLE_TIME := 0.2

var _pressed := false
var _dragging := false
var _origin := Vector2.ZERO
var _speed := 0.0
var _arrow := NariButton.new()

func _ready() -> void:
	layer = 128
	_arrow.corner_radius = 1000.0
	_arrow.padding = 0
	_arrow.size = Vector2.ONE * ARROW_SIZE
	_arrow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_arrow.focus_mode = Control.FOCUS_NONE
	_arrow.icon = preload("res://assets/icons/chevron_left.svg")
	_arrow.icon_size = Vector2.ONE * ARROW_SIZE * 0.7
	_arrow.hide()
	add_child(_arrow)

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.index == 0:
		_press(event.is_pressed() and not event.canceled, event.position)
	elif event is InputEventScreenDrag and event.index == 0 and _pressed:
		_move(event)

func _press(down: bool, point: Vector2) -> void:
	_pressed = down and point.x < get_viewport().get_visible_rect().size.x * EDGE_SHARE
	_origin = point
	if down or not _dragging:
		return
	_dragging = false
	get_viewport().set_input_as_handled()
	if _arrow.modulate.a >= 1.0 or _speed > BACK_SPEED:
		Main.go_back()
	var tween := create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(_arrow, "modulate:a", 0.0, SETTLE_TIME)
	tween.tween_callback(_arrow.hide)

func _move(event: InputEventScreenDrag) -> void:
	var delta := event.position - _origin
	if not _dragging:
		if delta.x < START_DISTANCE or delta.x < absf(delta.y) * HORIZONTAL_BIAS:
			_pressed = delta.length() <= START_DISTANCE
			return
		_dragging = true
		_arrow.show()
	get_viewport().set_input_as_handled()
	_speed = event.velocity.x
	var progress := clampf(delta.x / (get_viewport().get_visible_rect().size.x * BACK_SHARE), 0.0, 1.0)
	_arrow.modulate.a = progress
	_arrow.position = Vector2(lerpf(-ARROW_SIZE, ARROW_SIZE * 0.5, progress), event.position.y - ARROW_SIZE * 0.5)
