class_name EqualizerBand extends Control

signal value_changed(value: float)

const TRACK_WIDTH := 14.0
const KNOB_SIZE := Vector2(52.0, 30.0)
const EDGE := KNOB_SIZE.y * 0.5
const FOCUS_SCALE := 1.25

var dimmed := false:
	set(on):
		dimmed = on
		queue_redraw()
var value := 0.0:
	set(amount):
		value = clampf(amount, -Equalizer.RANGE, Equalizer.RANGE)
		queue_redraw()

var _dragging := false

func _init() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	custom_minimum_size = Vector2(KNOB_SIZE.x * FOCUS_SCALE, 320.0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _ready() -> void:
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	InputGlyphs.mode_changed.connect(queue_redraw.unbind(1))
	ThemeEngine.follow(self, queue_redraw)

func _gui_input(event: InputEvent) -> void:
	var direction := int(event.is_action_pressed("ui_up", true)) - int(event.is_action_pressed("ui_down", true))
	if direction != 0:
		accept_event()
		_set_from_user(snappedf(value + Equalizer.STEP * direction, Equalizer.STEP))
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		accept_event()
		_dragging = event.pressed and not event.double_click
		if event.pressed:
			grab_focus()
			_set_from_user(0.0 if event.double_click else _value_at(event.position.y))
	elif event is InputEventMouseMotion and _dragging:
		accept_event()
		_set_from_user(_value_at(event.position.y))

func _set_from_user(amount: float) -> void:
	if not is_equal_approx(clampf(amount, -Equalizer.RANGE, Equalizer.RANGE), value):
		value = amount
		value_changed.emit(value)

func _value_at(y: float) -> float:
	return snappedf(remap(y, EDGE, size.y - EDGE, Equalizer.RANGE, -Equalizer.RANGE), 0.1)

func _y_of(amount: float) -> float:
	return remap(amount, Equalizer.RANGE, -Equalizer.RANGE, EDGE, size.y - EDGE)

func _draw() -> void:
	var alpha := 0.45 if dimmed else 1.0
	var line := ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	var fill := ThemeEngine.get_color(ThemeEngine.Colors.AccentBg)
	var middle := size.x * 0.5
	var zero := _y_of(0.0)
	var at := _y_of(value)
	_rounded(Rect2(middle - TRACK_WIDTH * 0.5, EDGE, TRACK_WIDTH, size.y - EDGE * 2.0), Color(line, line.a * 0.25 * alpha))
	draw_line(Vector2(middle - TRACK_WIDTH * 1.6, zero), Vector2(middle + TRACK_WIDTH * 1.6, zero), Color(line, 0.5 * alpha), 3.0, true)
	if absf(at - zero) > 0.5:
		_rounded(Rect2(middle - TRACK_WIDTH * 0.5, minf(at, zero), TRACK_WIDTH, absf(at - zero)), Color(fill, fill.a * alpha))
	var selected := has_focus() and InputGlyphs.navigating()
	var knob_size := KNOB_SIZE * (FOCUS_SCALE if selected or _dragging else 1.0)
	var knob := Rect2(Vector2(middle, at) - knob_size * 0.5, knob_size)
	if selected:
		_rounded(knob.grow(6.0), Color(line, 0.9 * alpha))
	_rounded(knob, Color(ThemeEngine.get_color(ThemeEngine.Colors.AccentGradient), alpha))

func _rounded(rect: Rect2, color: Color) -> void:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(int(minf(rect.size.x, rect.size.y) * 0.5))
	box.anti_aliasing = true
	draw_style_box(box, rect)
