@tool
class_name NariLineEdit extends LineEdit

@export var use_custom_colors:bool = false:
	set(v):
		use_custom_colors = v
		_setup_theme()

@export var bg_color:ThemeEngine.Colors = ThemeEngine.Colors.PanelFg:
	set(v):
		bg_color = v
		_setup_theme()
@export var fg_color:ThemeEngine.Colors = ThemeEngine.Colors.PanelBg:
	set(v):
		fg_color = v
		_setup_theme()
@export var custom_bg_color:Color = Color("FFFFFF"):
	set(v):
		custom_bg_color = v
		_setup_theme()
@export var custom_fg_color:Color = Color("000000"):
	set(v):
		custom_fg_color = v
		_setup_theme()

@export_group("Text")
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
) var font_weight:int = 400:
	set(v):
		font_weight = v
		_setup_theme()
@export var font_size:int = 26:
	set(v):
		font_size = v
		_setup_theme()
@export_range(0.0, 1.0, 0.05) var placeholder_alpha:float = 0.5:
	set(v):
		placeholder_alpha = v
		_setup_theme()
@export_range(0.0, 1.0, 0.05) var uneditable_alpha:float = 0.6:
	set(v):
		uneditable_alpha = v
		_setup_theme()

@export_group("Border")
@export var border_color:ThemeEngine.Colors = ThemeEngine.Colors.PanelBg:
	set(v):
		border_color = v
		_setup_theme()
@export var custom_border_color:Color = Color("112853"):
	set(v):
		custom_border_color = v
		_setup_theme()
@export var border_width:int = 4:
	set(v):
		border_width = v
		_setup_theme()

@export_group("Focus")
@export var focus_color:ThemeEngine.Colors = ThemeEngine.Colors.AccentBg:
	set(v):
		focus_color = v
		_setup_theme()
@export var custom_focus_color:Color = Color("009CFF"):
	set(v):
		custom_focus_color = v
		_setup_theme()
@export var focus_border_width:int = 4:
	set(v):
		focus_border_width = v
		_setup_theme()
@export_range(0.0, 1.0, 0.05) var selection_alpha:float = 0.35:
	set(v):
		selection_alpha = v
		_setup_theme()

@export_group("Shape")
@export var corner_radius:int = 28:
	set(v):
		corner_radius = v
		corner_top_left = v
		corner_top_right = v
		corner_bottom_right = v
		corner_bottom_left = v
@export var corner_top_left:int = 28:
	set(v):
		corner_top_left = v
		_setup_theme()
@export var corner_top_right:int = 28:
	set(v):
		corner_top_right = v
		_setup_theme()
@export var corner_bottom_right:int = 28:
	set(v):
		corner_bottom_right = v
		_setup_theme()
@export var corner_bottom_left:int = 28:
	set(v):
		corner_bottom_left = v
		_setup_theme()
@export var padding:int = 16:
	set(v):
		padding = v
		_setup_theme()
@export var horizontal_padding:int = 28:
	set(v):
		horizontal_padding = v
		_setup_theme()
@export var leading_space:int = 0:
	set(v):
		leading_space = v
		_setup_theme()
@export var text_hidden:bool = false:
	set(v):
		text_hidden = v
		_setup_theme()

var _normal := StyleBoxFlat.new()
var _focus := StyleBoxFlat.new()

func _init() -> void:
	_normal.anti_aliasing = false
	_focus.anti_aliasing = false

	_focus.draw_center = false

func _ready() -> void:
	add_theme_stylebox_override("normal", _normal)
	add_theme_stylebox_override("read_only", _normal)
	add_theme_stylebox_override("focus", _focus)
	ThemeEngine.follow(self, _setup_theme)
	_setup_theme()

func _setup_theme() -> void:
	var bg:Color = ThemeEngine.resolve(use_custom_colors, custom_bg_color, bg_color)
	var fg:Color = ThemeEngine.resolve(use_custom_colors, custom_fg_color, fg_color)
	var accent:Color = ThemeEngine.resolve(use_custom_colors, custom_focus_color, focus_color)
	var border:Color = ThemeEngine.resolve(use_custom_colors, custom_border_color, border_color)

	for box in [_normal, _focus]:
		if box.corner_radius_top_left == corner_top_left and box.content_margin_top == padding and box.content_margin_left == horizontal_padding + leading_space:
			continue
		box.corner_radius_top_left = corner_top_left
		box.corner_radius_top_right = corner_top_right
		box.corner_radius_bottom_right = corner_bottom_right
		box.corner_radius_bottom_left = corner_bottom_left
		box.content_margin_top = padding
		box.content_margin_bottom = padding
		box.content_margin_left = horizontal_padding + leading_space
		box.content_margin_right = horizontal_padding

	if _normal.bg_color != bg:
		_normal.bg_color = bg
	if _normal.border_color != border:
		_normal.border_color = border
	if _normal.border_width_top != border_width:
		_normal.set_border_width_all(border_width)
	if _focus.border_color != accent:
		_focus.border_color = accent
	if _focus.border_width_top != focus_border_width:
		_focus.set_border_width_all(focus_border_width)

	var write_color: = func(key: StringName, value: Color):
		if has_theme_color_override(key) and get_theme_color(key) == value:
			return
		add_theme_color_override(key, value)

	if not has_theme_font_size_override("font_size") or get_theme_font_size("font_size") != font_size:
		add_theme_font_size_override("font_size", font_size)
	if ThemeEngine.font_weights.has(font_weight):
		var variation: Font = ThemeEngine.font_weights[font_weight]
		if not has_theme_font_override("font") or get_theme_font("font") != variation:
			add_theme_font_override("font", variation)

	write_color.call("font_color", Color.TRANSPARENT if text_hidden else fg)
	write_color.call("font_selected_color", fg)
	write_color.call("font_placeholder_color", Color(fg, fg.a * placeholder_alpha))
	write_color.call("font_uneditable_color", Color(fg, fg.a * uneditable_alpha))
	write_color.call("caret_color", Color.TRANSPARENT if text_hidden else accent)
	write_color.call("selection_color", Color(accent, selection_alpha))
	write_color.call("clear_button_color", Color(fg, fg.a * uneditable_alpha))
	write_color.call("clear_button_color_pressed", accent)
