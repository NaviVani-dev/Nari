class_name ColorChoice

const PALETTE := [ThemeEngine.Colors.AnimBgColor1, ThemeEngine.Colors.AnimBgColor2, ThemeEngine.Colors.AnimBgColor3, ThemeEngine.Colors.BlueBg, ThemeEngine.Colors.TealBg, ThemeEngine.Colors.GreenBg,
	ThemeEngine.Colors.LimeBg, ThemeEngine.Colors.YellowBg, ThemeEngine.Colors.OrangeBg, ThemeEngine.Colors.RedBg, ThemeEngine.Colors.PinkBg, ThemeEngine.Colors.PurpleBg, ThemeEngine.Colors.IndigoBg]
const CUSTOM_ICON := preload("res://assets/icons/edit.svg")
const SWATCH := 88.0
const COLUMNS := 7

static func color_of(value: Variant) -> Color:
	return value if value is Color else ThemeEngine.get_color(PALETTE[clampi(int(value), 0, PALETTE.size() - 1)]) if value is int or value is float else Color.from_string(str(value), Color.WHITE)

static func open(title: String, config: Dictionary, chose: Callable) -> void:
	var current := color_of(config["get"].call())
	var options: Array = config.get("palette", range(PALETTE.size()).map(func(index: int): return {"color": index}))
	var dialog := Dialog.menu(title)
	var swatches := GridContainer.new()
	swatches.columns = COLUMNS
	swatches.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	for gap in ["h_separation", "v_separation"]:
		swatches.add_theme_constant_override(gap, 24)
	for listed: Variant in options:
		var option: Dictionary = listed if listed is Dictionary else {"color": listed}
		var color := color_of(option["color"])
		swatches.add_child(_swatch(color, Dialog.CHECK if color.is_equal_approx(current) else null, func():
			dialog.close()
			config["set"].call(option.get("value", "#" + color.to_html(false)))
			chose.call()))
	if config.get("custom", true):
		swatches.add_child(_swatch(current, CUSTOM_ICON, func():
			dialog.close()
			_custom(title, current, config, chose)))
	dialog.content.add_child(swatches)
	dialog.popup()

static func _swatch(color: Color, icon: Texture2D, action: Callable) -> NariButton:
	var swatch := NariButton.new()
	swatch.custom_minimum_size = Vector2.ONE * SWATCH
	swatch.corner_radius = 1000.0
	swatch.icon_size = Vector2.ONE * SWATCH * 0.5
	swatch.use_custom_colors = true
	swatch.custom_bg_color = color
	swatch.custom_gradient_color = color
	swatch.custom_fg_color = Color.BLACK if color.get_luminance() > 0.6 else Color.WHITE
	swatch.icon = icon
	swatch.pressed.connect(action)
	return swatch

static func _custom(title: String, start: Color, config: Dictionary, chose: Callable) -> void:
	var dialog := Dialog.menu(title)
	var area := ColorPad.new()
	var hue := ColorPad.new()
	var hex := Dialog.text_button("", func(): Dialog.ask("Hex color", "#" + area.color().to_html(false).to_upper(), false, func(text: String):
		var typed := Color.from_string(text.strip_edges(), area.color())
		area.hsv = Vector3(typed.h, typed.s, typed.v)
		area.changed.emit()))
	area.custom_minimum_size.y = 360
	hue.custom_minimum_size.y = 56
	hue.hue_bar = true
	hex.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hex.use_custom_colors = true
	var show := func(hsv: Vector3):
		area.hsv = hsv
		hue.hsv = hsv
		area.queue_redraw()
		hue.queue_redraw()
		var color := area.color()
		hex.text = "#" + color.to_html(false).to_upper()
		hex.custom_bg_color = color
		hex.custom_gradient_color = color
		hex.custom_fg_color = Color.BLACK if color.get_luminance() > 0.6 else Color.WHITE
	area.changed.connect(func(): show.call(area.hsv))
	hue.changed.connect(func(): show.call(Vector3(hue.hsv.x, area.hsv.y, area.hsv.z)))
	for control in [area, hue, hex]:
		var spaced := MarginContainer.new()
		spaced.add_theme_constant_override("margin_bottom", 32)
		spaced.add_child(control)
		dialog.content.add_child(spaced)
	show.call(Vector3(start.h, start.s, start.v))
	dialog.add_button("Cancel")
	dialog.add_button("Save", func():
		config["set"].call("#" + area.color().to_html(false))
		chose.call(), Dialog.Style.PRIMARY)
	dialog.popup()
