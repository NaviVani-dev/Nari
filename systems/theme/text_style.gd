@tool
class_name TextStyle

const DEFAULT_SCOPE: = "default"
const FILL_CODE: = Color(1.0, 0.0, 0.0)
const OUTLINE_CODE: = Color(0.0, 1.0, 0.0)
const SHADOW_CODE: = Color(0.0, 0.0, 1.0)
const SHADOW_SHADE: = Color(0.25, 0.25, 0.25)
const CLEAR: = Color(0.0, 0.0, 0.0, 0.0)

static func scope_of(node: Node) -> String:
	if node.has_meta(&"text_scope"):
		return node.get_meta(&"text_scope")
	if not node.is_inside_tree():
		return DEFAULT_SCOPE
	var scope: = DEFAULT_SCOPE
	var parent: = node.get_parent()
	while parent:
		if parent.has_meta(&"theme_page"):
			scope = parent.get_meta(&"theme_page")
			break
		parent = parent.get_parent()
	node.set_meta(&"text_scope", scope)
	return scope

static func apply(label: Label, paint: Paint, weight: int, size: int) -> void:
	var style: Dictionary = {} if Engine.is_editor_hint() else Themes.text_style(scope_of(label))
	var font_size: = maxi(roundi(size * float(style.get("size", 1.0))), 1)
	var own_weight: = int(style.get("weight", weight))
	if bool(style.get("bold", false)):
		own_weight = maxi(own_weight, 700)
	own_weight = clampi(snappedi(own_weight, 100), 100, 900)
	var font: Font = ThemeEngine.font_weights.get(own_weight) if Engine.is_editor_hint() else Themes.text_font(style, own_weight)
	if font and (not label.has_theme_font_override("font") or label.get_theme_font("font") != font):
		label.add_theme_font_override("font", font)
	if not label.has_theme_font_size_override("font_size") or label.get_theme_font_size("font_size") != font_size:
		label.add_theme_font_size_override("font_size", font_size)
	if not label.has_meta(&"own_uppercase"):
		label.set_meta(&"own_uppercase", label.uppercase)
	var uppercase: bool = label.get_meta(&"own_uppercase") or bool(style.get("uppercase", false))
	if label.uppercase != uppercase:
		label.uppercase = uppercase

	var fill: Paint = style.get("color", paint)
	var outline_size: = int(style.get("outline_size", 0))
	var outline: Paint = style.get("outline", Paint.solid(CLEAR))
	var shadow: Paint = style.get("shadow")
	var offset: Vector2 = style.get("shadow_offset", Vector2.ZERO)
	if shadow == null and ThemeEngine.font_shadow > 0.0 and not Engine.is_editor_hint():
		shadow = Paint.solid(Color(fill.color * SHADOW_SHADE, fill.color.a))
		offset = Vector2.ONE * roundi(font_size * ThemeEngine.font_shadow)
	if shadow == null:
		shadow = Paint.solid(CLEAR)
		offset = Vector2.ZERO
	_constant(label, &"outline_size", outline_size)
	_constant(label, &"shadow_offset_x", roundi(offset.x))
	_constant(label, &"shadow_offset_y", roundi(offset.y))
	_constant(label, &"shadow_outline_size", int(style.get("shadow_blur", 0)))
	if style.has("line_spacing"):
		_constant(label, &"line_spacing", int(style["line_spacing"]))
		label.set_meta(&"styled_lines", true)
	elif label.has_meta(&"styled_lines"):
		label.remove_meta(&"styled_lines")
		label.remove_theme_constant_override(&"line_spacing")

	var own: ShaderMaterial = label.get_meta(&"text_material") if label.has_meta(&"text_material") else null
	var painted: = not fill.is_solid() or outline_size > 0 and not outline.is_solid() or offset != Vector2.ZERO and not shadow.is_solid()
	if painted and (label.material == null or label.material == own):
		if own == null:
			own = ShaderMaterial.new()
			own.shader = Paint.SHADER
			own.set_shader_parameter("text", true)
			label.set_meta(&"text_material", own)
			label.resized.connect(func(): own.set_shader_parameter("paint_size", label.size))
		fill.bind(own, "fill")
		outline.bind(own, "outline")
		shadow.bind(own, "shadow")
		own.set_shader_parameter("paint_size", label.size)
		label.material = own
		_tint(label, FILL_CODE, OUTLINE_CODE, SHADOW_CODE)
		return
	if own and label.material == own:
		label.material = null
	_tint(label, fill.color, outline.color, shadow.color)

static func _tint(label: Label, fill: Color, outline: Color, shadow: Color) -> void:
	if label.self_modulate.r != 1.0 or label.self_modulate.g != 1.0 or label.self_modulate.b != 1.0:
		label.self_modulate = Color(1.0, 1.0, 1.0, label.self_modulate.a)
	_color(label, &"font_color", fill)
	_color(label, &"font_outline_color", outline)
	_color(label, &"font_shadow_color", shadow)

static func _color(label: Label, key: StringName, value: Color) -> void:
	if not label.has_theme_color_override(key) or label.get_theme_color(key) != value:
		label.add_theme_color_override(key, value)

static func _constant(label: Label, key: StringName, value: int) -> void:
	if not label.has_theme_constant_override(key) or label.get_theme_constant(key) != value:
		label.add_theme_constant_override(key, value)
