@tool
class_name DistortionPad extends Control

signal distortion_changed(speed: float, pitch: float)

@export var standalone: bool = false

const STEP := 0.125
const CELLS := 4
const GRID_ALPHA := 0.08
const AXIS_ALPHA := 0.2
const LINE := 2.0
const HANDLE_SHARE := 0.2
const HANDLE_RANGE := Vector2(48.0, 96.0)
const ICON_SHARE := 0.9
const SIDES := [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]
const SEND_INTERVAL := 250
const SEND_DELTA := 0.015

@export var handle: Control:
	set(value):
		handle = value
		queue_redraw()

@export var icons: Array[Control] = []

var _offset := Vector2.ZERO
var _sent := Vector2.ZERO
var _dragging := false
var _pending := false
var _sent_at := 0

func _ready() -> void:
	set_process(false)
	ThemeEngine.follow(self, queue_redraw)
	queue_redraw()
	if Engine.is_editor_hint() or standalone:
		return
	MediaPlayer.music_effect_changed.connect(sync)
	sync(MediaPlayer.get_music_effect_state())

func _process(_delta: float) -> void:
	if _pending and Time.get_ticks_msec() - _sent_at >= SEND_INTERVAL:
		if _offset.distance_to(_sent) >= SEND_DELTA:
			_send()
		else:
			_pending = false
	set_process(_pending)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event is InputEventMouseButton and event.button_index != MOUSE_BUTTON_LEFT:
			return
		if event.is_pressed():
			_dragging = true
			_aim(event.position)
		elif _dragging:
			_dragging = false
			queue_redraw()
			_send()
		accept_event()
	elif _dragging and (event is InputEventScreenDrag or event is InputEventMouseMotion):
		_aim(event.position)
		accept_event()

func _draw() -> void:
	if ThemeEngine.current_theme == null:
		return
	var middle := size * 0.5
	handle.size = Vector2.ONE * clampf(minf(size.x, size.y) * HANDLE_SHARE, HANDLE_RANGE.x, HANDLE_RANGE.y)
	var travel := _travel()
	handle.position = middle + Vector2(_offset.x, -_offset.y) * travel - handle.size * 0.5
	for index in icons.size():
		icons[index].size = handle.size * ICON_SHARE
		icons[index].position = middle + SIDES[index] * (travel + handle.size * 0.25) - icons[index].size * 0.5
	var foreground := ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	var area := Rect2(middle - travel, travel * 2.0)
	for tick in range(-CELLS, CELLS + 1):
		var color := Color(foreground, AXIS_ALPHA if tick == 0 else GRID_ALPHA)
		var at := middle + travel * tick / CELLS
		draw_line(Vector2(at.x, area.position.y), Vector2(at.x, area.end.y), color, LINE, true)
		draw_line(Vector2(area.position.x, at.y), Vector2(area.end.x, at.y), color, LINE, true)
	draw_arc(middle, handle.size.x * 0.3, 0.0, TAU, 48, Color(foreground, AXIS_ALPHA * 2.0), LINE, true)

func _travel() -> Vector2:
	var extent := handle.size if handle else Vector2.ZERO
	return (size - extent) * 0.5

func _aim(point: Vector2) -> void:
	var travel := _travel()
	var reach := (point - size * 0.5) / Vector2(maxf(travel.x, 1.0), maxf(travel.y, 1.0))
	_offset = Vector2(snappedf(clampf(reach.x, -1.0, 1.0), STEP), snappedf(clampf(-reach.y, -1.0, 1.0), STEP))
	_push()

func nudge(direction: Vector2) -> void:
	_offset = (_offset + direction * STEP).clamp(-Vector2.ONE, Vector2.ONE)
	_push()

func reset() -> void:
	_offset = Vector2.ZERO
	_push()

func _push() -> void:
	queue_redraw()
	if Time.get_ticks_msec() - _sent_at < SEND_INTERVAL or _offset.distance_to(_sent) < SEND_DELTA:
		_pending = true
		set_process(true)
		return
	_send()

func _send() -> void:
	if Engine.is_editor_hint():
		return
	_sent_at = Time.get_ticks_msec()
	_sent = _offset
	_pending = false
	var speed: = pow(2.0, _offset.x)
	var pitch: = pow(2.0, _offset.y)
	distortion_changed.emit(speed, pitch)
	if not standalone:
		MediaPlayer.apply_music_distortion(speed, pitch)

func sync(state: Dictionary) -> void:
	if _dragging or _pending:
		return
	var factor := func(value: float): return snappedf(clampf(log(maxf(value, 0.01)) / log(2.0), -1.0, 1.0), STEP)
	_offset = Vector2(factor.call(float(state.get("speed", 1.0))), factor.call(float(state.get("pitch", 1.0))))
	queue_redraw()
