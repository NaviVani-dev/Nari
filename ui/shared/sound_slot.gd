class_name SoundSlot extends Control

signal tapped
signal held
signal drag_started

const ADD_ICON := preload("res://assets/icons/add.svg")
const LOOP_ICON := preload("res://assets/icons/repeat.svg")
const DRAG_DISTANCE := 28.0
const ROUNDNESS := 0.16
const RING := 6.0
const IDLE := 0.3
const FADE := 5.0
const PRESSED_SCALE := 0.94

var slot := -1
var interactive := false
var occupied := false:
	set(value):
		occupied = value
		queue_redraw()
var selected := false:
	set(value):
		selected = value
		queue_redraw()
var settings := {}:
	set(value):
		settings = value
		queue_redraw()

var _light := 0.0
var _hovered := false
var _looping := false
var _box := StyleBoxFlat.new()
var _gesture := TapGesture.new(self)
var _travelled := 0.0
var _dragging := false

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	_box.anti_aliasing = true
	_gesture.long_press = func() -> bool:
		if occupied and not _dragging:
			held.emit()
			return true
		return false
	_gesture.tapped.connect(func():
		if not _dragging:
			tapped.emit())
	_gesture.pressed.connect(_press.bind(PRESSED_SCALE))
	_gesture.released.connect(_press.bind(1.0))
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	mouse_entered.connect(_hover.bind(true))
	mouse_exited.connect(_hover.bind(false))
	resized.connect(func(): pivot_offset = size * 0.5)

func _ready() -> void:
	ThemeEngine.follow(self, queue_redraw)
	InputGlyphs.mode_changed.connect(queue_redraw.unbind(1))

func _gui_input(event: InputEvent) -> void:
	if interactive and occupied and _gesture.held and (event is InputEventScreenDrag or event is InputEventMouseMotion):
		_travelled += event.relative.length()
		if _travelled > DRAG_DISTANCE and not _dragging:
			_dragging = true
			drag_started.emit()
	if (event is InputEventScreenTouch or event is InputEventMouseButton) and event.is_pressed():
		_travelled = 0.0
		_dragging = false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.is_pressed() and occupied:
		accept_event()
		held.emit()
	elif _gesture.feed(event):
		accept_event()

func light(level: float, looping: bool, delta: float) -> void:
	var target := 1.0 if looping else minf(level * 2.0, 1.0)
	_light = target if target > _light else move_toward(_light, target, delta * FADE)
	if _looping != looping or _light > 0.0 or target > 0.0:
		_looping = looping
		queue_redraw()

func _draw() -> void:
	var side := minf(size.x, size.y)
	var color := Soundboard.tint(settings)
	var foreground := ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	var lit := has_focus() and InputGlyphs.navigating() or _hovered
	_box.set_corner_radius_all(int(side * ROUNDNESS * ThemeEngine.shape_radius))
	_box.bg_color = color.darkened(0.6).lerp(color, maxf(IDLE * (2.0 if lit else 1.0), _light)) if occupied else Color(foreground, 0.18 if lit else 0.06)
	_box.shadow_color = Color(color, 0.6 * _light)
	_box.shadow_size = int(side * 0.12 * _light)
	_box.set_border_width_all(int(RING) if lit or selected else 0)
	_box.border_color = ThemeEngine.get_color(ThemeEngine.Colors.AccentBg) if lit else foreground
	draw_style_box(_box, Rect2(Vector2.ZERO, size))
	if not occupied and interactive:
		_icon(ADD_ICON, side * 0.3, Color(foreground, 0.9 if lit else 0.35))
	elif settings.get("loop", false):
		_icon(LOOP_ICON, side * 0.28, Color(foreground, 1.0 if _looping else 0.6))

func _icon(texture: Texture2D, side: float, tint: Color) -> void:
	draw_texture_rect(texture, Rect2((size - Vector2.ONE * side) * 0.5, Vector2.ONE * side), false, tint)

func _hover(on: bool) -> void:
	_hovered = on and not OS.has_feature("mobile")
	queue_redraw()

func _press(target: float) -> void:
	if Main.reduce_motion:
		return
	create_tween().tween_property(self, "scale", Vector2.ONE * target, 0.08).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
