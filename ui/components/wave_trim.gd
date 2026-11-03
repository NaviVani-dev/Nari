class_name WaveTrim extends Control

signal trimmed
signal committed
signal seeked(at: float)

const HANDLE := 14.0
const REACH := 72.0
const STEP := 0.01
const SHORTEST := 0.02

var peaks := PackedByteArray()
var start := 0.0
var end := 1.0
var played := 0.0
var color := Color.WHITE

var _grabber := 0
var _editing := false
var _dragging := -1
var _handle := StyleBoxFlat.new()

func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_entered.connect(queue_redraw)
	focus_exited.connect(func():
		_finish()
		queue_redraw())

func go_back() -> bool:
	if not _editing:
		return false
	_finish()
	return true

func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		var at: float = event.position.x / size.x
		if event.is_pressed():
			_dragging = 0 if absf(at - start) <= absf(at - end) else 1
			if absf(at - [start, end][_dragging]) * size.x > REACH:
				_dragging = -1
				seeked.emit(inverse_lerp(start, end, at))
		elif _dragging >= 0:
			_dragging = -1
			committed.emit()
	elif _dragging >= 0 and (event is InputEventScreenDrag or event is InputEventMouseMotion):
		accept_event()
		_move(_dragging, event.position.x / size.x)
	elif event.is_action_pressed("ui_accept"):
		accept_event()
		if _editing:
			_finish()
		else:
			_editing = true
			queue_redraw()
	else:
		var direction := int(event.is_action_pressed("ui_right", true)) - int(event.is_action_pressed("ui_left", true))
		if direction == 0:
			return
		accept_event()
		if _editing:
			_move(_grabber, [start, end][_grabber] + direction * STEP)
		else:
			_grabber = clampi(_grabber + direction, 0, 1)
			queue_redraw()

func _move(which: int, at: float) -> void:
	if which == 0:
		start = clampf(at, 0.0, end - SHORTEST)
	else:
		end = clampf(at, start + SHORTEST, 1.0)
	trimmed.emit()
	queue_redraw()

func _finish() -> void:
	if _editing:
		_editing = false
		committed.emit()
		queue_redraw()

func _draw() -> void:
	var foreground := ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	var bar := size.x / maxi(peaks.size(), 1)
	for index in peaks.size():
		var at := (index + 0.5) / peaks.size()
		var height := maxf(peaks[index] / 255.0 * size.y * 0.8, bar * 0.5)
		draw_rect(Rect2(index * bar + bar * 0.2, (size.y - height) * 0.5, bar * 0.6, height), color if at >= start and at <= end else Color(foreground, 0.2))
	draw_rect(Rect2(lerpf(start, end, played) * size.x - 1.5, size.y * 0.1, 3.0, size.y * 0.8), Color(foreground, 0.7))
	_handle.set_corner_radius_all(int(HANDLE))
	for which in 2:
		var chosen := has_focus() and InputGlyphs.navigating() and which == _grabber
		var width := HANDLE * (1.6 if chosen and _editing else 1.0)
		_handle.bg_color = ThemeEngine.get_color(ThemeEngine.Colors.AccentBg) if chosen else foreground
		draw_style_box(_handle, Rect2([start, end][which] * size.x - width * 0.5, 0.0, width, size.y))
