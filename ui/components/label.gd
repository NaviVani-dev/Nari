@tool
class_name NariLabel extends Label

@export var use_custom_color: bool = false:
	set(val):
		use_custom_color = val
		_restyle()
@export var color: ThemeEngine.Colors = ThemeEngine.Colors.Foreground:
	set(val):
		color = val
		_restyle()
@export var custom_color: Color = Color.WHITE:
	set(val):
		custom_color = val
		_restyle()
@export_range(100,900,100,"prefer_slider") var weight:int = 500:
	set(val):
		if val > 0:
			weight = val
		_restyle()
@export var font_size: int = 18:
	set(val):
		font_size = val
		_restyle()
@export var marquee: bool = false:
	set(val):
		marquee = val
		if val:
			autowrap_mode = TextServer.AUTOWRAP_OFF
			max_lines_visible = 1
			clip_text = true
		_update_marquee_process()
		_restart_marquee()

@export_range(0.1, 1.0) var skeleton_width: float = 0.6

var underline: = false:
	set(value):
		if underline == value:
			return
		underline = value
		queue_redraw()

var skeleton: = false:
	set(value):
		if skeleton == value:
			return
		skeleton = value
		if value:
			_stop_reveal()
			_saved_min_width = custom_minimum_size.x
			custom_minimum_size.x = maxf(_saved_min_width, get_theme_font_size("font_size") * SKELETON_MIN_WIDTH)
		else:
			custom_minimum_size.x = _saved_min_width
			_reveal()
		_update_marquee_process()
		_restart_marquee()
		queue_redraw()

const MARQUEE_SPEED: = 110.0
const SKELETON_PULSE: = 1.4
const SKELETON_ALPHA: = Vector2(0.08, 0.2)
const SKELETON_HEIGHT: = 0.62
const SKELETON_MIN_WIDTH: = 5.0
const SKELETON_MAX_WIDTH: = 14.0
const MARQUEE_HOLD: = 1.4
const MARQUEE_FADE: = 0.22
const REVEAL_TIME: = 0.25

var _skeleton_box: StyleBoxFlat
var _reveal_tween: Tween
var _reveal_alpha: = 1.0
var _saved_min_width: = 0.0
var _marquee: Tween
var _marquee_text: = ""
var _marquee_width: = 0.0
var _base_alpha: = 1.0
var _scrolling: = false
var _saved_overrun: = -1
var _scroll: = 0.0:
	set(value):
		_scroll = value
		queue_redraw()

func _process(_delta: float) -> void:
	if skeleton:
		queue_redraw()
		return
	if text == _marquee_text and is_equal_approx(size.x, _marquee_width):
		return
	_marquee_text = text
	_marquee_width = size.x
	_restart_marquee()

func _draw() -> void:
	if skeleton:
		var font_height: = float(get_theme_font_size("font_size"))
		var bar: = Vector2(clampf(size.x * skeleton_width, minf(font_height * SKELETON_MIN_WIDTH, size.x), font_height * SKELETON_MAX_WIDTH), font_height * SKELETON_HEIGHT)
		var left: = (size.x - bar.x) * 0.5 if horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER else 0.0
		var pulse: = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * TAU / SKELETON_PULSE)
		if not _skeleton_box:
			_skeleton_box = StyleBoxFlat.new()
		_skeleton_box.bg_color = Color(1.0, 1.0, 1.0, lerpf(SKELETON_ALPHA.x, SKELETON_ALPHA.y, pulse))
		_skeleton_box.set_corner_radius_all(int(bar.y * 0.5))
		draw_style_box(_skeleton_box, Rect2(Vector2(left, (size.y - bar.y) * 0.5), bar))
		return
	if not _scrolling and not underline:
		return
	var font: Font = get_theme_font("font")
	var height: = get_theme_font_size("font_size")
	var baseline: = (size.y - font.get_height(height)) * 0.5 + font.get_ascent(height)
	if _scrolling:
		var shadow: = Vector2(get_theme_constant("shadow_offset_x"), get_theme_constant("shadow_offset_y"))
		var outline: = get_theme_constant("outline_size")
		var start: = Vector2(-_scroll, baseline)
		if shadow != Vector2.ZERO:
			draw_string(font, start + shadow, _shown_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, height, get_theme_color("font_shadow_color"))
		if outline > 0:
			draw_string_outline(font, start, _shown_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, height, outline, get_theme_color("font_outline_color"))
		draw_string(font, start, _shown_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, height, get_theme_color("font_color"))
	if underline:
		_draw_underline(font, height, baseline)

func _draw_underline(font: Font, height: int, baseline: float) -> void:
	var width: = font.get_string_size(_shown_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, height).x
	var left: = -_scroll if _scrolling else 0.0
	if not _scrolling:
		width = minf(width, size.x)
		match horizontal_alignment:
			HORIZONTAL_ALIGNMENT_CENTER:
				left = (size.x - width) * 0.5
			HORIZONTAL_ALIGNMENT_RIGHT:
				left = size.x - width
	var thickness: = maxf(font.get_underline_thickness(height), 2.0)
	var y: = baseline + font.get_underline_position(height) + thickness * 0.5
	draw_line(Vector2(maxf(left, 0.0), y), Vector2(minf(left + width, size.x), y), get_theme_color("font_color"), thickness)

func _restart_marquee() -> void:
	if _marquee and _marquee.is_valid():
		_marquee.kill()
	_scroll = 0.0
	_scrolling = false
	visible_characters = 0 if skeleton else -1
	if _saved_overrun >= 0:
		text_overrun_behavior = _saved_overrun as TextServer.OverrunBehavior
		_saved_overrun = -1
	if not is_node_ready() or Engine.is_editor_hint():
		return
	modulate.a = _base_alpha
	if skeleton or not marquee or not is_visible_in_tree():
		return
	var font: Font = get_theme_font("font")
	if not font:
		return
	var overflow: = font.get_string_size(_shown_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, get_theme_font_size("font_size")).x - size.x
	if overflow <= 1.0 or size.x <= 0.0:
		return
	_scrolling = true
	_saved_overrun = text_overrun_behavior
	text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	clip_contents = true
	visible_characters_behavior = TextServer.VC_CHARS_AFTER_SHAPING
	visible_characters = 0
	_marquee = create_tween().set_loops()
	_marquee.tween_interval(MARQUEE_HOLD)
	_marquee.tween_property(self, "_scroll", overflow, overflow / MARQUEE_SPEED)
	_marquee.tween_interval(MARQUEE_HOLD)
	_marquee.tween_property(self, "modulate:a", 0.0, MARQUEE_FADE)
	_marquee.tween_callback(func(): _scroll = 0.0)
	_marquee.tween_property(self, "modulate:a", _base_alpha, MARQUEE_FADE)

func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and (marquee or skeleton) and is_node_ready():
		_update_marquee_process()
		_restart_marquee()

func _update_marquee_process() -> void:
	set_process((marquee or skeleton) and not Engine.is_editor_hint() and (not is_inside_tree() or is_visible_in_tree()))

func _ready() -> void:
	_base_alpha = modulate.a
	_update_marquee_process()
	if marquee:
		_restart_marquee()
	if ThemeEngine.has_method("follow"):
		ThemeEngine.follow(self, _setup_theme)
	_setup_theme()

func _setup_theme() -> void:
	if ThemeEngine.current_theme == null:
		return
	if not Engine.is_editor_hint():
		Themes.shade(self, "label")
	_restyle()
	if not Engine.is_editor_hint() and material is ShaderMaterial:
		material.set_shader_parameter("font_size", float(get_theme_font_size("font_size")))

func _stop_reveal() -> void:
	if _reveal_tween:
		_reveal_tween.kill()
		_reveal_tween = null
		self_modulate.a = _reveal_alpha

func _reveal() -> void:
	_stop_reveal()
	if Engine.is_editor_hint() or not is_inside_tree() or Main.reduce_motion:
		return
	_reveal_alpha = self_modulate.a
	self_modulate.a = 0.0
	_reveal_tween = create_tween()
	_reveal_tween.tween_property(self, "self_modulate:a", _reveal_alpha, REVEAL_TIME)

func _restyle() -> void:
	if not is_node_ready() or not use_custom_color and ThemeEngine.current_theme == null:
		return
	var shape: = [get_theme_font("font"), get_theme_font_size("font_size"), uppercase]
	TextStyle.apply(self, ThemeEngine.resolve_paint(use_custom_color, custom_color, color), weight, font_size)
	if marquee and shape != [get_theme_font("font"), get_theme_font_size("font_size"), uppercase]:
		_restart_marquee()

func _shown_text() -> String:
	return text.to_upper() if uppercase else text
