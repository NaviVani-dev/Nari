class_name NariSwitch extends Control

const SIZE := Vector2(112.0, 64.0)
const INSET := 7.0
const SLIDE_TIME := 0.2

var on := false
var _shift := 0.0
var _track := NariPanelContainer.new()
var _knob := NariPanelContainer.new()
var _slide: Tween

func _init() -> void:
	custom_minimum_size = SIZE
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for part: NariPanelContainer in [_track, _knob]:
		part.mouse_filter = Control.MOUSE_FILTER_IGNORE
		part.padding = 0
		add_child(part)
	_track.corner_radius = SIZE.y * 0.5
	_knob.corner_radius = SIZE.y * 0.5 - INSET

func _ready() -> void:
	resized.connect(_place)
	_paint()
	_place()

func set_on(value: bool, animate: bool = true) -> void:
	on = value
	_paint()
	if _slide:
		_slide.kill()
	var target := 1.0 if on else 0.0
	if not animate or Main.reduce_motion or not is_inside_tree():
		_shift = target
		_place()
		return
	_slide = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_slide.tween_method(func(shift: float):
		_shift = shift
		_place(), _shift, target, SLIDE_TIME)

func _place() -> void:
	_track.position = Vector2.ZERO
	_track.size = size
	var side := maxf(size.y - INSET * 2.0, 0.0)
	_knob.size = Vector2.ONE * side
	_knob.position = Vector2(INSET + _shift * maxf(size.x - side - INSET * 2.0, 0.0), INSET)

func _paint() -> void:
	_track.bg_color = ThemeEngine.Colors.AccentBg if on else ThemeEngine.Colors.Background
	_track.gradient_color = ThemeEngine.Colors.AccentGradient if on else ThemeEngine.Colors.BackgroundTint
	_knob.bg_color = ThemeEngine.Colors.AccentFg if on else ThemeEngine.Colors.Foreground
	_knob.gradient_color = _knob.bg_color
