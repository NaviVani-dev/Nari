@tool
class_name NariButton extends NariPanelContainer

const DEPTH_HAZE_AMOUNT: = 0.6
const INDICATOR_RATIO: = 0.2
const HOVER_SCALE: = 1.02
const PRESS_SCALE: = 0.97
const SCALE_TIME: = 0.12

signal pressed
signal button_down
signal button_up
signal toggled(status: bool)
signal context_requested

@export_multiline var text: = "":
	set(v):
		text = v
		_update_label()
@export var icon: Texture2D:
	set(v):
		icon = v
		_update_icon()
@export var flat: = false:
	set(v):
		flat = v
		_setup_theme()

@export_group("Text Behavior")
@export var horizontal_alignment: HorizontalAlignment = HORIZONTAL_ALIGNMENT_CENTER:
	set(v):
		horizontal_alignment = v
		_update_label()
@export var vertical_alignment: VerticalAlignment = VERTICAL_ALIGNMENT_CENTER:
	set(v):
		vertical_alignment = v
		_update_label()
@export var autowrap_mode: TextServer.AutowrapMode = TextServer.AUTOWRAP_OFF:
	set(v):
		autowrap_mode = v
		_update_label()
@export var clip_text: bool = false:
	set(v):
		clip_text = v
		_update_label()
@export var text_overrun_behavior: TextServer.OverrunBehavior = TextServer.OVERRUN_NO_TRIMMING:
	set(v):
		text_overrun_behavior = v
		_update_label()
@export var ellipsis_char: String = "…":
	set(v):
		ellipsis_char = v
		_update_label()
@export var uppercase: bool = false:
	set(v):
		uppercase = v
		_update_label()
@export_enum(
	"Thin:100",
	"ExtraLight:200",
	"Light:300",
	"Normal:400",
	"Medium:500",
	"SemiBold:600",
	"Bold:700",
	"ExtraBold:800",
	"Black:900"
) var font_weight: int = 400:
	set(v):
		if v > 0:
			font_weight = v
		_update_label()
@export var font_size: int = 26:
	set(v):
		font_size = v
		_update_label()

@export_group("Icon Behavior")
@export var expand_mode: TextureRect.ExpandMode = TextureRect.EXPAND_FIT_WIDTH:
	set(v):
		expand_mode = v
		_update_icon()
@export var stretch_mode: TextureRect.StretchMode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED:
	set(v):
		stretch_mode = v
		_update_icon()
@export var flip_h: bool = false:
	set(v):
		flip_h = v
		_update_icon()
@export var flip_v: bool = false:
	set(v):
		flip_v = v
		_update_icon()
@export var icon_size: Vector2 = Vector2.ZERO:
	set(v):
		icon_size = v
		_update_icon()
@export var use_icon_color: bool = false:
	set(v):
		use_icon_color = v
		_update_icon()
@export var icon_color: ThemeEngine.Colors = ThemeEngine.Colors.PanelFg:
	set(v):
		icon_color = v
		_update_icon()

@export_group("Layout")
@export var vertical: bool = false:
	set(v):
		vertical = v
		if _row:
			_row.vertical = v
@export var alignment: BoxContainer.AlignmentMode = BoxContainer.ALIGNMENT_CENTER:
	set(v):
		alignment = v
		if _row:
			_row.alignment = v
@export var separation: int = 8:
	set(v):
		separation = v
		if _row:
			_row.add_theme_constant_override("separation", v)
@export var icon_right: bool = false:
	set(v):
		icon_right = v
		if _row:
			_row.move_child(_icon, -1 if v else 0)

@export_group("Foreground")
@export var fg_color: ThemeEngine.Colors = ThemeEngine.Colors.PanelFg:
	set(v):
		fg_color = v
		_setup_theme()
@export var custom_fg_color: Color = Color("FFFFFF"):
	set(v):
		custom_fg_color = v
		_setup_theme()
@export var accent_on_focus: = false:
	set(v):
		accent_on_focus = v
		_setup_theme()
@export var focus_bg_color: ThemeEngine.Colors = ThemeEngine.Colors.AccentBg
@export var focus_gradient_color: ThemeEngine.Colors = ThemeEngine.Colors.AccentGradient
@export var focus_fg_color: ThemeEngine.Colors = ThemeEngine.Colors.AccentFg
@export var indicator: = false:
	set(v):
		indicator = v
		if _dot:
			_dot.visible = v

@export_category("BaseButton")
@export var disabled: = false:
	set(v):
		disabled = v
		_update_state()
@export var toggle_mode: = false:
	set(v):
		toggle_mode = v
		_update_state()
@export var button_pressed: = false:
	set(v):
		button_pressed = v
		toggled.emit(v)
		_update_state()
@export var action_mode: BaseButton.ActionMode = BaseButton.ACTION_MODE_BUTTON_RELEASE

var custom_fg_paint: Paint
var _row: BoxContainer
var _icon: Icon
var _label: Label
var _dot: Control
var _gesture: TapGesture
var _depth_effect: float = 0.0
var _hovered: = false
var scales: = true
var _scale_tween: Tween

func _init() -> void :
	super ()
	corner_radius = 28.0
	padding = 12

	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	_row = BoxContainer.new()
	_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_row.alignment = alignment
	_row.add_theme_constant_override("separation", separation)
	_icon = Icon.new()
	_icon.themed = false
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row.add_child(_icon)
	_row.add_child(_label)
	add_child(_row, false, INTERNAL_MODE_FRONT)
	_dot = Control.new()
	_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_dot.visible = false
	_dot.draw.connect(_draw_dot)
	_row.sort_children.connect(_dot.queue_redraw)
	add_child(_dot, false, INTERNAL_MODE_FRONT)
	focus_entered.connect(_setup_theme)
	focus_exited.connect(_setup_theme)
	mouse_entered.connect(_hover.bind(true))
	mouse_exited.connect(_hover.bind(false))

	_gesture = TapGesture.new(self)
	_gesture.long_press = func() -> bool:
		if context_requested.get_connections().is_empty():
			return false
		context_requested.emit()
		return true
	_gesture.pressed.connect( func():
		_update_state()
		_animate_scale()
		button_down.emit()
		if action_mode == BaseButton.ACTION_MODE_BUTTON_PRESS:
			_emit_pressed())
	_gesture.released.connect( func():
		_update_state()
		_animate_scale()
		button_up.emit())

	_gesture.tapped.connect( func():
		if action_mode == BaseButton.ACTION_MODE_BUTTON_RELEASE:
			_emit_pressed()
		if focus_mode != Control.FOCUS_NONE and InputGlyphs.navigating():
			grab_focus())

func _ready() -> void :
	super ()
	_row.vertical = vertical
	_row.alignment = alignment
	_row.add_theme_constant_override("separation", separation)
	_row.move_child(_icon, -1 if icon_right else 0)
	_dot.visible = indicator
	if accent_on_focus and not Engine.is_editor_hint():
		InputGlyphs.mode_changed.connect(_setup_theme.unbind(1))
	_update_label()
	_update_icon()
	_update_state()
	if not Engine.is_editor_hint():
		offset_transform_enabled = true
		offset_transform_pivot_ratio = Vector2.ONE * 0.5
		offset_transform_visual_only = true

func _hover(hovered: bool) -> void:
	_hovered = hovered
	if not Engine.is_editor_hint() and Themes.styles.get(_style_kind(), {}).has("focus"):
		_setup_theme()
	_animate_scale()

func _animate_scale() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	var target: = 1.0
	if scales and _gesture.held and Themes.enabled("motion", "press"):
		target = PRESS_SCALE
	elif scales and _hovered and not disabled and not OS.has_feature("mobile") and Themes.enabled("motion", "hover"):
		target = HOVER_SCALE
	if _scale_tween:
		_scale_tween.kill()
	if Main.reduce_motion:
		offset_transform_scale = Vector2.ONE * target
		return
	_scale_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_scale_tween.tween_property(self, "offset_transform_scale", Vector2.ONE * target, SCALE_TIME)

func _gui_input(event: InputEvent) -> void :
	if disabled:
		return
	var right_click: bool = event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT
	if (right_click or event.is_action_pressed("ui_select")) and not context_requested.get_connections().is_empty():
		context_requested.emit()
		accept_event()
		return
	if _gesture.feed(event):
		accept_event()

func add_leading(control: Control) -> void:
	_row.add_child(control)
	_row.move_child(control, 0)

func is_held() -> bool:
	return _gesture.held

func cancel_press() -> void :
	_gesture.cancel()

func marquee_on_focus(labels: Array) -> void :
	var scroll: = func(enabled: bool):
		for label in labels:
			label.marquee = enabled
	focus_entered.connect(scroll.bind(true))
	focus_exited.connect(scroll.bind(false))

func set_depth(depth: float) -> void :
	var clamped: = clampf(depth, 0.0, 1.0)
	if is_equal_approx(clamped, _depth_effect):
		return
	_depth_effect = clamped
	_setup_theme()

func _setup_theme() -> void :
	if not is_node_ready():
		return
	super ()
	if _depth_effect > 0.0:
		var haze: = ThemeEngine.get_color(ThemeEngine.Colors.Background)
		var amount: = _depth_effect * DEPTH_HAZE_AMOUNT
		_paint_fill(_fill_paint().tinted(haze, amount))
		_paint_gradient(_glow_paint().tinted(haze, amount))
	if _accented():
		_paint_fill(ThemeEngine.get_paint(focus_bg_color))
		_paint_gradient(ThemeEngine.get_paint(focus_gradient_color))
	elif flat:
		_paint_fill(Paint.solid(Color(1.0, 1.0, 1.0, 0.0)))
		_paint_gradient(Paint.solid(Color(1.0, 1.0, 1.0, 0.0)))
	_update_label()
	_update_icon()

func _style_kind() -> String:
	return "button" if not flat or _accented() else ""

func _highlighted() -> bool:
	return not disabled and (has_focus() and InputGlyphs.navigating() or _hovered and not OS.has_feature("mobile"))

func _shader_kind() -> String:
	return "button"

func _spacing_kind() -> String:
	return "button" if not flat or accent_on_focus else ""

func _emit_pressed() -> void :
	if toggle_mode:
		button_pressed = not button_pressed
	pressed.emit()

func _update_state() -> void :
	modulate.a = 0.75 if disabled else 1.0
	mouse_default_cursor_shape = Control.CURSOR_ARROW if disabled else Control.CURSOR_POINTING_HAND
	self_modulate = Color.WHITE

func _update_label() -> void :
	if not _label or not is_node_ready():
		return
	_label.visible = not text.is_empty()
	_label.text = text
	_label.horizontal_alignment = horizontal_alignment
	_label.vertical_alignment = vertical_alignment
	_label.autowrap_mode = autowrap_mode
	_label.clip_text = clip_text
	_label.text_overrun_behavior = text_overrun_behavior
	_label.ellipsis_char = ellipsis_char
	_label.uppercase = uppercase
	_label.set_meta(&"own_uppercase", uppercase)
	TextStyle.apply(_label, _foreground_paint(), font_weight, font_size)

func _update_icon() -> void :
	if not _icon:
		return
	_icon.visible = icon != null
	_icon.texture = icon
	_icon.expand_mode = expand_mode
	_icon.stretch_mode = stretch_mode
	_icon.custom_minimum_size = icon_size
	_icon.flip_h = flip_h
	_icon.flip_v = flip_v
	if ThemeEngine.icons_colored:
		Paint.tint(_icon, Paint.solid(Color.WHITE))
	elif use_icon_color:
		Paint.tint(_icon, ThemeEngine.get_paint(icon_color))
	else:
		Paint.tint(_icon, _foreground_paint())
	if _dot:
		_dot.queue_redraw()

func _accented() -> bool:
	return accent_on_focus and has_focus() and InputGlyphs.navigating()

func _draw_dot() -> void :
	var bottom: = size.y - _dot.position.y
	var icon_bottom: = _row.position.y + _icon.position.y + _icon.size.y - _dot.position.y
	var gap: = bottom - icon_bottom
	_dot.draw_circle(Vector2(_dot.size.x * 0.5, icon_bottom + gap * 0.5), gap * INDICATOR_RATIO, _foreground_color(), true, -1.0, true)

func _foreground_color() -> Color:
	return _foreground_paint().color

func _foreground_paint() -> Paint:
	var paint: = ThemeEngine.resolve_paint(use_custom_colors, custom_fg_color, fg_color)
	if _accented():
		paint = ThemeEngine.get_paint(focus_fg_color)
	elif use_custom_colors and custom_fg_paint:
		paint = custom_fg_paint
	return paint.tinted(ThemeEngine.get_color(ThemeEngine.Colors.Background), _depth_effect * DEPTH_HAZE_AMOUNT)
