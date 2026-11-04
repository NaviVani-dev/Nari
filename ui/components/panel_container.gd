@tool
class_name NariPanelContainer extends PanelContainer

const PANEL_SHADER := preload("res://assets/shaders/panel.gdshader")
const GRADIENT_BLUR := 24.0
const GRADIENT_OPACITY := 0.75

@export var use_custom_colors:bool = false:
	set(v):
		use_custom_colors = v
		_setup_theme()

@export var bg_color:ThemeEngine.Colors = ThemeEngine.Colors.PanelBg:
	set(v):
		bg_color = v
		_setup_theme()
@export var gradient_color:ThemeEngine.Colors = ThemeEngine.Colors.PanelGradient:
	set(v):
		gradient_color = v
		_setup_theme()
@export var custom_bg_color:Color = Color("FFFFFF"):
	set(v):
		custom_bg_color = v
		_setup_theme()
@export var custom_gradient_color:Color = Color("FFFFFF"):
	set(v):
		custom_gradient_color = v
		_setup_theme()

@export var corner_radius:float = 24.0:
	set(v):
		corner_radius = v
		corner_top_left = v
		corner_top_right = v
		corner_bottom_right = v
		corner_bottom_left = v
@export var corner_top_left:float = 24.0:
	set(v):
		corner_top_left = v
		_setup_theme()
@export var corner_top_right:float = 24.0:
	set(v):
		corner_top_right = v
		_setup_theme()
@export var corner_bottom_right:float = 24.0:
	set(v):
		corner_bottom_right = v
		_setup_theme()
@export var corner_bottom_left:float = 24.0:
	set(v):
		corner_bottom_left = v
		_setup_theme()
@export var padding:int = 16:
	set(v):
		padding = v
		padding_left = v
		padding_top = v
		padding_right = v
		padding_bottom = v
@export var padding_left:int = 16:
	set(v):
		padding_left = v
		_setup_theme()
@export var padding_top:int = 16:
	set(v):
		padding_top = v
		_setup_theme()
@export var padding_right:int = 16:
	set(v):
		padding_right = v
		_setup_theme()
@export var padding_bottom:int = 16:
	set(v):
		padding_bottom = v
		_setup_theme()

var custom_bg_paint: Paint
var custom_gradient_paint: Paint
var style := StyleBoxFlat.new()
var _material := ShaderMaterial.new()
var _textured: StyleBoxTexture
var _texture_source: StyleBoxTexture
var _texture_modulate := true

func _init() -> void:
	_material.shader = PANEL_SHADER
	style.bg_color = Color.WHITE
	style.anti_aliasing = false

func _ready() -> void:
	material = _material
	add_theme_stylebox_override("panel", style)
	ThemeEngine.follow(self, _setup_theme)
	_setup_theme()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_material.set_shader_parameter("panel_size", size)
		_fit_margins()

func _fit_margins() -> void:
	if _textured == null or _texture_source == null:
		return
	var across := _texture_source.texture_margin_left + _texture_source.texture_margin_right
	var down := _texture_source.texture_margin_top + _texture_source.texture_margin_bottom
	var factor := minf(1.0, minf(size.x / maxf(across, 1.0), size.y / maxf(down, 1.0)))
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		var margin := _texture_source.get_texture_margin(side) * factor
		if not is_equal_approx(_textured.get_texture_margin(side), margin):
			_textured.set_texture_margin(side, margin)

func _setup_theme() -> void:
	if not is_node_ready():
		return
	var _bg := _fill_paint()
	var _gr := _glow_paint()

	var themed: Dictionary = Themes.styles.get(_style_kind(), {}) if not Engine.is_editor_hint() else {}
	var spacing: Dictionary = themed if not themed.is_empty() or Engine.is_editor_hint() else Themes.styles.get(_spacing_kind(), {})
	var extra: PackedFloat32Array = spacing.get("padding", PackedFloat32Array([0.0, 0.0, 0.0, 0.0]))
	if themed.is_empty():
		if _textured:
			_textured = null
			_texture_source = null
			add_theme_stylebox_override("panel", style)
			texture_filter = TEXTURE_FILTER_PARENT_NODE
	elif _texture_source != _box_of(themed):
		_texture_source = _box_of(themed)
		_textured = _texture_source.duplicate()
		_texture_modulate = themed["modulate"]
		_set_content_margins(_textured, extra)
		_fit_margins()
		add_theme_stylebox_override("panel", _textured)
		texture_filter = themed["filter"]
	_set_content_margins(_textured if _textured else style, extra)
	var shaded := not Engine.is_editor_hint() and Themes.dress(_shader_kind(), _material, PANEL_SHADER)
	material = _material if shaded or _textured == null else null

	_paint_fill(_bg)
	_paint_gradient(_gr)
	_material.set_shader_parameter("gradient_blur", GRADIENT_BLUR * ThemeEngine.shape_blur)
	_material.set_shader_parameter("panel_size", size)
	_material.set_shader_parameter("corner_radius", Vector4(corner_top_left, corner_top_right, corner_bottom_right, corner_bottom_left) * ThemeEngine.shape_radius)

func _set_content_margins(box: StyleBox, extra: PackedFloat32Array) -> void:
	var margins := [padding_left, padding_top, padding_right, padding_bottom]
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		if box.get_content_margin(side) != margins[side] + extra[side]:
			box.set_content_margin(side, margins[side] + extra[side])

func _box_of(themed: Dictionary) -> StyleBoxTexture:
	return themed["focus"] if _highlighted() and themed.has("focus") else themed["box"]

func _highlighted() -> bool:
	return false

func _style_kind() -> String:
	return "panel"

func _spacing_kind() -> String:
	return _style_kind()

func _shader_kind() -> String:
	return "panel"

func _fill_paint() -> Paint:
	if use_custom_colors and custom_bg_paint:
		return custom_bg_paint
	return ThemeEngine.resolve_paint(use_custom_colors, custom_bg_color, bg_color)

func _glow_paint() -> Paint:
	if use_custom_colors and custom_gradient_paint:
		return custom_gradient_paint
	return ThemeEngine.resolve_paint(use_custom_colors, custom_gradient_color, gradient_color)

func _paint_fill(paint: Paint) -> void:
	paint.bind(_material, "fill")
	if _textured:
		_textured.modulate_color = paint.color if _texture_modulate else Color.WHITE

func _paint_gradient(paint: Paint) -> void:
	var faded := paint.faded(GRADIENT_OPACITY)
	_material.set_shader_parameter("gradient_color", faded.color)
	_material.set_shader_parameter("gradient_style", faded.style())
	if not faded.is_solid():
		_material.set_shader_parameter("gradient_paint", faded.texture())
