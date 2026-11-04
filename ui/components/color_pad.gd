class_name ColorPad extends Control

signal changed

const STEP := 0.02
const KNOB := 22.0
const SEGMENTS := 6

var hue_bar := false
var hsv := Vector3(0.0, 1.0, 1.0)

func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)

func color() -> Color:
	return Color.from_hsv(hsv.x, hsv.y, hsv.z)

func _gui_input(event: InputEvent) -> void:
	var touched: bool = (event is InputEventScreenTouch or event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT) and event.is_pressed()
	if touched or event is InputEventScreenDrag or event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		accept_event()
		_place((event.position / size).clamp(Vector2.ZERO, Vector2.ONE))
		return
	var direction := Vector2(int(event.is_action_pressed("ui_right", true)) - int(event.is_action_pressed("ui_left", true)), 0.0 if hue_bar else int(event.is_action_pressed("ui_down", true)) - int(event.is_action_pressed("ui_up", true)))
	var at := _at()
	var moved := (at + direction * STEP).clamp(Vector2.ZERO, Vector2.ONE)
	if moved != at:
		accept_event()
		_place(moved)

func _at() -> Vector2:
	return Vector2(hsv.x, 0.5) if hue_bar else Vector2(hsv.y, 1.0 - hsv.z)

func _place(at: Vector2) -> void:
	if hue_bar:
		hsv.x = at.x
	else:
		hsv.y = at.x
		hsv.z = 1.0 - at.y
	changed.emit()
	queue_redraw()

func _draw() -> void:
	if hue_bar:
		for index in SEGMENTS:
			var left := size.x * index / SEGMENTS
			var right := size.x * (index + 1) / SEGMENTS
			var colors := [Color.from_hsv(float(index) / SEGMENTS, 1.0, 1.0), Color.from_hsv(float(index + 1) / SEGMENTS, 1.0, 1.0)]
			draw_polygon([Vector2(left, 0.0), Vector2(right, 0.0), Vector2(right, size.y), Vector2(left, size.y)], [colors[0], colors[1], colors[1], colors[0]])
	else:
		draw_polygon([Vector2.ZERO, Vector2(size.x, 0.0), size, Vector2(0.0, size.y)], [Color.WHITE, Color.from_hsv(hsv.x, 1.0, 1.0), Color.BLACK, Color.BLACK])
	var knob := _at() * size
	var ring := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg) if has_focus() and InputGlyphs.navigating() else Color.WHITE
	draw_circle(knob, KNOB, Color.from_hsv(hsv.x, 1.0, 1.0) if hue_bar else color(), true, -1.0, true)
	draw_circle(knob, KNOB, ring, false, 6.0, true)
