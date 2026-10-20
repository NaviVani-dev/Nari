@tool
class_name ProgressSlider extends HSlider

const TRACK_HEIGHT := 30.0
const GRABBER_SIZE := Vector2(16.5, 42.0)
const TRACK_SHADER := preload("res://assets/shaders/progress_slider.gdshader")
const GRABBER_TEXTURE := preload("res://assets/images/grabber.svg")
const MIN_BUFFERED := 0.005
const UNBUFFERED_ALPHA := 0.5
const SEEK_STEP := 5000.0
const STICK_SETTLE := 0.75

var _track := ColorRect.new()
var _grabber := Icon.new()
var _material := ShaderMaterial.new()
var _last_ratio := -1.0
var _last_size := Vector2.ZERO
var _shown := 0.0
var _held := false
var _buffered_wait := 0.0
var _buffered := PackedVector2Array()
var _settle := 0.0

@export var show_grabber: bool = true:
	set(value):
		show_grabber = value
		_refresh_grabber()
@export var grabber_on_hover: bool = false:
	set(value):
		grabber_on_hover = value
		_refresh_grabber()

@export var show_buffered: bool = false
@export var nudge: float = SEEK_STEP
@export var scale_height: float = 1.0:
	set(value):
		scale_height = value
		_fit_height()

var playing: bool = false
var _hovered := false

func _init() -> void:
	step = 1.0
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	var empty_style := StyleBoxEmpty.new()
	add_theme_stylebox_override("slider", empty_style)
	add_theme_stylebox_override("grabber_area", empty_style)
	add_theme_stylebox_override("grabber_area_highlight", empty_style)
	var empty_image := Image.create_empty(1, 1, false, Image.FORMAT_RGBA8)
	empty_image.fill(Color.TRANSPARENT)
	var empty_texture := ImageTexture.create_from_image(empty_image)
	add_theme_icon_override("grabber", empty_texture)
	add_theme_icon_override("grabber_highlight", empty_texture)
	add_theme_icon_override("grabber_disabled", empty_texture)

	_material.shader = TRACK_SHADER
	_track.material = _material
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_track.set_anchors_preset(Control.PRESET_HCENTER_WIDE)
	add_child(_track)

	_grabber.themed = false
	_grabber.texture = GRABBER_TEXTURE
	_grabber.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_grabber.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_grabber.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_grabber)
	_fit_height()

func _fit_height() -> void:
	custom_minimum_size.y = _grabber_size().y
	_track.offset_top = -_track_height() * 0.5
	_track.offset_bottom = _track_height() * 0.5
	_grabber.size = _grabber_size()
	_last_ratio = -1.0
	queue_redraw()

func _track_height() -> float:
	return TRACK_HEIGHT * scale_height

func _grabber_size() -> Vector2:
	return GRABBER_SIZE * scale_height

func _ready() -> void:
	drag_started.connect(func():
		_held = true
		_refresh_grabber())
	drag_ended.connect(func(_changed: bool):
		_held = false
		_refresh_grabber())
	if grabber_on_hover:
		mouse_entered.connect(func():
			_hovered = true
			_refresh_grabber())
		mouse_exited.connect(func():
			_hovered = false
			_refresh_grabber())
		focus_entered.connect(_refresh_grabber)
		focus_exited.connect(_refresh_grabber)
	ThemeEngine.follow(self, _setup_theme)
	_setup_theme()
	set_process(true)

func _gui_input(event: InputEvent) -> void:
	var direction := int(event.is_action_pressed("ui_right", true)) - int(event.is_action_pressed("ui_left", true))
	if direction == 0 or not editable:
		return
	accept_event()
	if not _held:
		drag_started.emit()
	value += nudge * direction
	if event.has_meta(&"stick"):
		_settle = STICK_SETTLE
	else:
		_commit()

func is_held() -> bool:
	return _held

func _commit() -> void:
	_settle = 0.0
	if _held:
		drag_ended.emit(true)

func _process(delta: float) -> void:
	if _settle > 0.0:
		_settle -= delta
		if _settle <= 0.0:
			_commit()
	if show_buffered and not Engine.is_editor_hint():
		_buffered_wait -= delta
		if _buffered_wait <= 0.0:
			_buffered_wait = 0.25
			_show_buffered(MediaPlayer.get_buffered())
	if _held or not playing or absf(value - _shown) > 1500.0:
		_shown = value
	else:
		_shown = lerpf(_shown + delta * 1000.0, value, clampf(delta * 6.0, 0.0, 1.0))
	_shown = clampf(_shown, min_value, max_value)
	var progress := clampf((_shown - min_value) / maxf(max_value - min_value, 0.0001), 0.0, 1.0)
	if is_equal_approx(progress, _last_ratio) and size.is_equal_approx(_last_size):
		return
	_last_ratio = progress
	_last_size = size
	var grabber_x := progress * maxf(size.x - _grabber_size().x, 0.0)
	_grabber.position = Vector2(grabber_x, (size.y - _grabber_size().y) * 0.5)
	_material.set_shader_parameter("progress", (grabber_x + _grabber_size().x * 0.5) / maxf(size.x, 1.0))
	_material.set_shader_parameter("control_size", Vector2(size.x, _track_height()))
	queue_redraw()

func _show_buffered(ranges: PackedVector2Array) -> void:
	if ranges == _buffered and size.is_equal_approx(_last_size):
		return
	_buffered = ranges
	var travel := maxf(size.x - _grabber_size().x, 0.0)
	var shown := PackedVector2Array()
	for part: Vector2 in ranges:
		if part.y - part.x >= MIN_BUFFERED and shown.size() < 8:
			shown.append(Vector2(_track_x(part.x, travel), _track_x(part.y, travel)))
	_material.set_shader_parameter("buffered_count", shown.size())
	shown.resize(8)
	_material.set_shader_parameter("buffered", shown)

func _track_x(ratio: float, travel: float) -> float:
	if ratio <= 0.0 or ratio >= 1.0:
		return clampf(ratio, 0.0, 1.0)
	return (ratio * travel + _grabber_size().x * 0.5) / maxf(size.x, 1.0)

func _setup_theme() -> void:
	if not Engine.is_editor_hint():
		Themes.dress("progress", _material, TRACK_SHADER)
		_track.visible = not Themes.styles.get("progress", {}).has("fill")
		queue_redraw()
	_material.set_shader_parameter("start_color", ThemeEngine.get_color(ThemeEngine.Colors.AccentBg))
	_material.set_shader_parameter("end_color", ThemeEngine.get_color(ThemeEngine.Colors.AccentGradient))
	var fg := ThemeEngine.get_color(ThemeEngine.Colors.PanelFg)
	_material.set_shader_parameter("remaining_color", Color(fg, fg.a * (UNBUFFERED_ALPHA if show_buffered else 1.0)))
	_material.set_shader_parameter("buffered_color", fg)

func _draw() -> void:
	if not Engine.is_editor_hint():
		Themes.draw_bar(self, _track.get_rect(), maxf(_last_ratio, 0.0))

func _refresh_grabber() -> void:
	_grabber.visible = show_grabber and (not grabber_on_hover or _held or _hovered or has_focus() and not Engine.is_editor_hint() and InputGlyphs.navigating())
