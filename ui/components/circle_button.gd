@tool
class_name CircleButton extends NariButton

const HAZE_AMOUNT := 0.6
const ICON_RATIO := 0.6

@export var color:ThemeEngine.Colors = ThemeEngine.Colors.AccentBg:
	set(v):
		color = v
		_refresh()
@export var gradient:ThemeEngine.Colors = ThemeEngine.Colors.AccentGradient:
	set(v):
		gradient = v
		_refresh()
@export var foreground:ThemeEngine.Colors = ThemeEngine.Colors.AccentFg:
	set(v):
		foreground = v
		_refresh()

var _depth:float = 0.0

func _init() -> void:
	super()
	use_custom_colors = true
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE

func _ready() -> void:
	super()
	ThemeEngine.follow(self, _refresh)
	var fit := func():
		var diameter := maxf(size.x, size.y)
		corner_radius = diameter * 0.5
		icon_size = Vector2.ONE * diameter * ICON_RATIO
		padding = int(diameter * (1.0 - ICON_RATIO) * 0.5)
	resized.connect(fit)
	fit.call()
	_refresh()

func _style_kind() -> String:
	return ""

func _spacing_kind() -> String:
	return ""

func set_depth(depth:float) -> void:
	_depth = clampf(depth, 0.0, 1.0)
	_refresh()

func _refresh() -> void:
	if not is_node_ready():
		return
	var haze := ThemeEngine.get_color(ThemeEngine.Colors.Background)
	var amount := _depth * HAZE_AMOUNT
	custom_bg_color = ThemeEngine.get_color(color).lerp(haze, amount)
	custom_gradient_color = ThemeEngine.get_color(gradient).lerp(haze, amount)
	custom_fg_color = ThemeEngine.get_color(foreground).lerp(haze, amount)
