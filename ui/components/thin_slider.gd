@tool
class_name ThinSlider extends Range

signal released

const GRABBER_RATIO := 3.0
const KEY_STEP := 0.05

@export var thickness: float = 8.0:
	set(v):
		thickness = v
		queue_redraw()
@export var vertical: bool = false:
	set(v):
		vertical = v
		queue_redraw()
@export var editable: bool = false:
	set(v):
		editable = v
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if v else Control.CURSOR_ARROW
@export var color: ThemeEngine.Colors = ThemeEngine.Colors.AccentFg:
	set(v):
		color = v
		queue_redraw()
@export_range(0.0, 1.0) var track_alpha: float = 0.3:
	set(v):
		track_alpha = v
		queue_redraw()
@export var grabber: Texture2D

var _dragging := false
var _hovered := false
var _box := StyleBoxFlat.new()
var _grabber_raster: Texture2D

func _ready() -> void:
	editable = editable
	value_changed.connect(queue_redraw.unbind(1))
	changed.connect(queue_redraw)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	mouse_entered.connect(func():
		_hovered = true
		queue_redraw())
	mouse_exited.connect(func():
		_hovered = false
		queue_redraw())
	ThemeEngine.follow(self, queue_redraw)

func _draw() -> void:
	if ThemeEngine.current_theme == null:
		return
	var tint := ThemeEngine.get_color(color)
	var length := size.y if vertical else size.x
	var across := size.x if vertical else size.y
	var line := minf(thickness, across)
	var radius := line * 0.5
	var track := tint
	track.a *= track_alpha
	var fill := length * clampf(ratio, 0.0, 1.0)
	var base := Transform2D(-PI * 0.5, Vector2(0.0, length)) if vertical else Transform2D.IDENTITY
	var textured := not Engine.is_editor_hint() and Themes.draw_bar(self, Rect2(0.0, (across - line) * 0.5, length, line), clampf(ratio, 0.0, 1.0), base)
	draw_set_transform(Vector2.ZERO)
	if not textured:
		_bar(0.0, length, line, across, radius, track)
		if fill > 0.0:
			_bar(length - maxf(fill, line) if vertical else 0.0, maxf(fill, line), line, across, radius, tint)
	if not editable or not (focus_mode == FOCUS_NONE or has_focus() and InputGlyphs.navigating() or _dragging or _hovered):
		return
	var at := length - fill if vertical else fill
	if not grabber:
		draw_circle(Vector2(across * 0.5, at) if vertical else Vector2(at, across * 0.5), line * 1.4, tint, true, -1.0, true)
		return
	var height := line * GRABBER_RATIO
	var width := height * grabber.get_width() / maxf(grabber.get_height(), 1.0)
	var along := clampf(at, width * 0.5, length - width * 0.5)
	_grabber_raster = Icon.rasterize(grabber, self, Vector2(width, height))
	if vertical:
		draw_set_transform(Vector2(across * 0.5, along), PI * 0.5)
		draw_texture_rect(_grabber_raster, Rect2(-width * 0.5, -height * 0.5, width, height), false)
		draw_set_transform(Vector2.ZERO)
		return
	var screen := Icon.screen_transform(self)
	var corner := (screen * Vector2(along - width * 0.5, (across - height) * 0.5)).round()
	draw_texture_rect(_grabber_raster, Rect2(screen.affine_inverse() * corner, _grabber_raster.get_size() / screen.get_scale().abs()), false)

func _bar(start: float, extent: float, line: float, across: float, radius: float, tint: Color) -> void:
	_box.bg_color = tint
	_box.set_corner_radius_all(ceili(radius))
	var offset := (across - line) * 0.5
	draw_style_box(_box, Rect2(offset, start, line, extent) if vertical else Rect2(start, offset, extent, line))

func _gui_input(event: InputEvent) -> void:
	if not editable:
		return
	var pointer: bool = event is InputEventScreenTouch or event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT
	if pointer:
		_dragging = event.is_pressed()
		if _dragging:
			_aim(event.position)
		else:
			released.emit()
		queue_redraw()
		accept_event()
	elif _dragging and (event is InputEventScreenDrag or event is InputEventMouseMotion):
		_aim(event.position)
		accept_event()
	elif not vertical and (event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right")):
		nudge(1 if event.is_action_pressed("ui_right") else -1)
		accept_event()
	elif vertical and (event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down")):
		nudge(1 if event.is_action_pressed("ui_up") else -1)
		accept_event()

func nudge(direction: int) -> void:
	value += (max_value - min_value) * KEY_STEP * direction
	released.emit()

func is_dragging() -> bool:
	return _dragging

func _aim(point: Vector2) -> void:
	var share := 1.0 - point.y / maxf(size.y, 1.0) if vertical else point.x / maxf(size.x, 1.0)
	value = lerpf(min_value, max_value, clampf(share, 0.0, 1.0))
