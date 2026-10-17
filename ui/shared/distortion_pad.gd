@tool
class_name DistortionPad extends Control

signal distortion_changed(speed: float, pitch: float)

@export var standalone: bool = false

const STEP := 0.125
const GRID_ALPHA := 0.45
const AXIS_ALPHA := 0.5
const SEND_INTERVAL := 250
const SEND_DELTA := 0.015

@export var handle: Control:
	set(value):
		handle = value
		queue_redraw()

@export var line_width: float = 8.0:
	set(value):
		line_width = value
		queue_redraw()

@export var line_color: ThemeEngine.Colors = ThemeEngine.Colors.Foreground:
	set(value):
		line_color = value
		queue_redraw()

@export var axis_color: ThemeEngine.Colors = ThemeEngine.Colors.Foreground:
	set(value):
		axis_color = value
		queue_redraw()

@export var keep_clear: Array[Control] = []:
	set(value):
		keep_clear = value
		queue_redraw()

@export var clear_margin: float = 16.0:
	set(value):
		clear_margin = value
		queue_redraw()

var _offset := Vector2.ZERO
var _sent := Vector2.ZERO
var _dragging := false
var _pending := false
var _sent_at := 0

func _ready() -> void:
	set_process(false)
	ThemeEngine.follow(self, queue_redraw)
	for control in keep_clear:
		if control:
			control.item_rect_changed.connect(queue_redraw)
	queue_redraw()
	if Engine.is_editor_hint() or standalone:
		return
	MediaPlayer.music_effect_changed.connect(_sync)
	_sync(MediaPlayer.get_music_effect_state())

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
	var travel := _travel()
	if handle:
		handle.position = middle + Vector2(_offset.x, -_offset.y) * travel - handle.size * 0.5
	var spacing := travel * STEP * 2.0
	if spacing.x <= 1.0 or spacing.y <= 1.0:
		return
	var axis := ThemeEngine.get_color(axis_color)
	axis.a *= AXIS_ALPHA
	var grid := ThemeEngine.get_color(line_color)
	grid.a *= AXIS_ALPHA * GRID_ALPHA
	var blocked: Array[Rect2] = []
	for control in keep_clear:
		if control and control.is_visible_in_tree():
			blocked.append(Rect2(control.global_position - global_position, control.size).grow(clear_margin))
	var line := func(horizontal: bool, at: float, color: Color, width: float):
		var length := size.x if horizontal else size.y
		var cuts: Array[Vector2] = []
		for rect in blocked:
			var across := Vector2(rect.position.y, rect.end.y) if horizontal else Vector2(rect.position.x, rect.end.x)
			if at >= across.x and at <= across.y:
				cuts.append(Vector2(rect.position.x, rect.end.x) if horizontal else Vector2(rect.position.y, rect.end.y))
		cuts.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
		cuts.append(Vector2(length, length))
		var start := 0.0
		for cut in cuts:
			var stop := minf(cut.x, length)
			if stop > start:
				draw_line(Vector2(start, at) if horizontal else Vector2(at, start), Vector2(stop, at) if horizontal else Vector2(at, stop), color, width, true)
			start = maxf(start, cut.y)
	var rows := floori(middle.y / spacing.y)
	for tick in range(-rows, rows + 1):
		var at := middle.y + tick * spacing.y
		if at > line_width and at < size.y - line_width:
			line.call(true, at, grid, line_width * 0.5)
	var columns := floori(middle.x / spacing.x)
	for tick in range(-columns, columns + 1):
		var at := middle.x + tick * spacing.x
		if at > line_width and at < size.x - line_width:
			line.call(false, at, grid, line_width * 0.5)
	line.call(true, middle.y, axis, line_width)
	line.call(false, middle.x, axis, line_width)

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

func _sync(state: Dictionary) -> void:
	if _dragging or _pending:
		return
	var factor := func(value: float): return snappedf(clampf(log(maxf(value, 0.01)) / log(2.0), -1.0, 1.0), STEP)
	_offset = Vector2(factor.call(float(state.get("speed", 1.0))), factor.call(float(state.get("pitch", 1.0))))
	queue_redraw()
