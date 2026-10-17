class_name SoundSlot extends Control

signal tapped
signal drag_started

const PANEL_SHADER := preload("res://assets/shaders/panel.gdshader")
const WAVE_SHADER := preload("res://assets/shaders/sound_wave.gdshader")
const DOTS := preload("res://assets/icons/more.svg")
const DOTS_RATIO := 0.52
const DRAG_DISTANCE := 28.0
const SELECTED_SCALE := 1.08
const RING_WIDTH := 6.0

var slot: int = -1
var draggable: bool = false

var occupied: bool = false:
	set(value):
		occupied = value
		if is_node_ready():
			_wave.visible = value
			_dots.visible = not value
			_paint()

var selected: bool = false:
	set(value):
		selected = value
		if is_node_ready():
			_grow(SELECTED_SCALE if value else 1.0)

var _circle := ColorRect.new()
var _wave := ColorRect.new()
var _dots := Icon.new()
var _panel := ShaderMaterial.new()
var _water := ShaderMaterial.new()
var _gesture: TapGesture
var _travelled := 0.0
var _dragging := false
var _scale: Tween

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	focus_mode = Control.FOCUS_ALL
	_panel.shader = PANEL_SHADER
	_water.shader = WAVE_SHADER
	for child in [_circle, _wave, _dots]:
		child.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(child)
	UI.fill(_circle)
	UI.fill(_wave)
	_dots.set_anchors_preset(Control.PRESET_CENTER, true)
	_circle.material = _panel
	_wave.material = _water
	_dots.themed = false
	_dots.texture = DOTS
	_dots.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_dots.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_gesture = TapGesture.new(self)
	_gesture.tapped.connect(func():
		if not _dragging:
			tapped.emit())
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)

func _ready() -> void:
	ThemeEngine.follow(self, _paint)
	InputGlyphs.mode_changed.connect(queue_redraw.unbind(1))
	resized.connect(_fit)
	_paint()
	_fit()
	_wave.visible = occupied
	_dots.visible = not occupied

func _gui_input(event: InputEvent) -> void:
	if draggable and _gesture.held and (event is InputEventScreenDrag or event is InputEventMouseMotion):
		_travelled += event.relative.length()
		if _travelled > DRAG_DISTANCE and not _dragging:
			_dragging = true
			drag_started.emit()
	if _gesture.feed(event):
		accept_event()
	if event is InputEventScreenTouch or event is InputEventMouseButton:
		if event.is_pressed():
			_travelled = 0.0
			_dragging = false

func _draw() -> void:
	if has_focus() and InputGlyphs.navigating():
		draw_arc(size * 0.5, minf(size.x, size.y) * 0.5 + RING_WIDTH * 0.5, 0.0, TAU, 96, ThemeEngine.get_color(ThemeEngine.Colors.AccentBg), RING_WIDTH, true)

func set_level(value: float) -> void:
	_water.set_shader_parameter("level", value)

func _fit() -> void:
	var diameter := minf(size.x, size.y)
	pivot_offset = size * 0.5
	_panel.set_shader_parameter("corner_radius", Vector4.ONE * diameter * 0.5)
	var dots := diameter * DOTS_RATIO * 0.5
	_dots.offset_left = -dots
	_dots.offset_top = -dots
	_dots.offset_right = dots
	_dots.offset_bottom = dots

func _paint() -> void:
	if ThemeEngine.current_theme == null:
		return
	var fill := ThemeEngine.Colors.PanelBg if occupied else ThemeEngine.Colors.Background
	var gradient := ThemeEngine.Colors.PanelGradient if occupied else ThemeEngine.Colors.BackgroundGradient
	_panel.set_shader_parameter("fill_color", ThemeEngine.get_color(fill))
	_panel.set_shader_parameter("gradient_color", ThemeEngine.get_color(gradient))
	_panel.set_shader_parameter("gradient_blur", 62.0)
	_water.set_shader_parameter("water_color", ThemeEngine.get_color((ThemeEngine.Colors.AnimBgColor1 + Soundboard.color_of(slot)) as ThemeEngine.Colors))
	_dots.self_modulate = ThemeEngine.get_color(ThemeEngine.Colors.Foreground)

func _grow(target: float) -> void:
	if _scale and _scale.is_valid():
		_scale.kill()
	_scale = create_tween()
	_scale.tween_property(self, "scale", Vector2.ONE * target, 0.16).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
