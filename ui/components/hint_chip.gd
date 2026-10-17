@tool
class_name HintChip extends NariButton

const FILL_ALPHA: = 0.1
const CYCLE_MS: = 5000
const FADE_TIME: = 0.3

var glyph: InputGlyphs.Glyph = InputGlyphs.Glyph.A:
	set(value):
		glyph = value
		_refresh_glyph()
var caption: String = "":
	set(value):
		if value == caption:
			return
		caption = value
		_arrange()
var compact: bool = false:
	set(value):
		if value == compact:
			return
		compact = value
		_arrange()

@export var solid: bool = false

var alternates: bool = false
var triggered: bool = true

var _glyph: TextureRect
var _glyph_shown: = false
var _fade: Tween

func _ready() -> void :
	super ()
	set_process(false)
	if Engine.is_editor_hint():
		return
	_glyph = TextureRect.new()
	_glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glyph.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glyph.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_glyph.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_glyph.custom_minimum_size = icon_size
	_row.add_child(_glyph)
	_row.move_child(_glyph, 0)
	InputGlyphs.mode_changed.connect(_arrange.unbind(1))
	InputGlyphs.device_changed.connect(_refresh_glyph.unbind(1))
	_refresh_glyph()
	_arrange()

func natural_width() -> float:
	var width: = float(padding_left + padding_right)
	if _has_face():
		width += icon_size.x
	if not caption.is_empty():
		var font: = _label.get_theme_font("font")
		width += font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, _label.get_theme_font_size("font_size")).x
		if _has_face():
			width += separation
	return width

func _face() -> Control:
	return _icon

func _has_face() -> bool:
	return icon != null

func _alternating() -> bool:
	return not compact and _has_face() and (alternates and InputGlyphs.glyphs() or InputGlyphs.dual and triggered)

func _arrange() -> void :
	if not _glyph:
		return
	var gamepad: = InputGlyphs.glyphs()
	if flat != (gamepad and not solid):
		flat = gamepad and not solid
	text = "" if compact and (_has_face() or gamepad) else caption
	var alternating: = _alternating()
	if alternating and _fade and _fade.is_running():
		set_process(true)
		return
	if _fade:
		_fade.kill()
	_glyph_shown = _glyph_phase() if alternating else gamepad and not _has_face()
	_glyph.modulate.a = 1.0
	_face().modulate.a = 1.0
	_apply_visibility()
	set_process(alternating)

func _apply_visibility() -> void :
	var gamepad: = InputGlyphs.glyphs()
	var alternating: = _alternating()
	var glyph_only: = gamepad and not compact and not alternates
	_glyph.visible = alternating and _glyph_shown or gamepad and (compact or glyph_only or not _has_face())
	_face().visible = _has_face() and not glyph_only and not (alternating and _glyph_shown)

func _glyph_phase() -> bool:
	return (Time.get_ticks_msec() / CYCLE_MS) % 2 == 1

func _process(_delta: float) -> void :
	if not _glyph:
		return
	var wanted: = _glyph_phase()
	if wanted != _glyph_shown:
		_swap(wanted)

func _swap(to_glyph: bool) -> void :
	_glyph_shown = to_glyph
	var leaving: Control = _face() if to_glyph else _glyph
	var entering: Control = _glyph if to_glyph else _face()
	if _fade:
		_fade.kill()
	_fade = create_tween()
	_fade.tween_property(leaving, "modulate:a", 0.0, FADE_TIME * 0.5)
	_fade.tween_callback( func():
		leaving.hide()
		entering.modulate.a = 0.0
		entering.show())
	_fade.tween_property(entering, "modulate:a", 1.0, FADE_TIME * 0.5)

func _refresh_glyph() -> void :
	if _glyph:
		_glyph.texture = InputGlyphs.get_glyph_texture(glyph)
		_glyph.texture_filter = Icon.filter_of(_glyph.texture)

func _update_icon() -> void :
	super ()
	if not _glyph:
		return
	_glyph.self_modulate = _foreground_color()
	if not (_fade and _fade.is_running()):
		_apply_visibility()

func _setup_theme() -> void :
	super ()
	if not is_node_ready() or flat or solid:
		return
	var fill: = ThemeEngine.get_color(fg_color)
	fill.a *= FILL_ALPHA
	_material.set_shader_parameter("fill_color", fill)
	_material.set_shader_parameter("gradient_color", fill)
