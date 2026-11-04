class_name EqualizerDialog extends RefCounted

const CHECK := preload("res://assets/icons/check.svg")
const TRASH := preload("res://assets/icons/delete.svg")
const CURVE_HEIGHT := 140.0
const CURVE_MARGIN := 32.0
const CURVE_STEPS := 16

var dialog: Dialog
var power: NariButton
var auto: NariButton
var preset: NariButton
var curve := Control.new()
var sliders: Array[EqualizerBand] = []
var readouts: Array[NariLabel] = []

static func open(refresh: Callable) -> void:
	var popup := EqualizerDialog.new()
	popup.dialog = Dialog.menu("Equalizer", "Shapes the sound of everything Nari plays")
	popup._build()
	var changed := func(section: String, _key: String, _value: Variant):
		if section == "equalizer":
			popup._sync()
	SettingsManager.changed.connect(changed)
	popup.dialog.closed.connect(func():
		SettingsManager.changed.disconnect(changed)
		refresh.call())
	popup._sync()
	popup.dialog.popup()

func _build() -> void:
	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 24)
	power = _toolbar_button("On", func(): SettingsManager.equalizer.enabled = not SettingsManager.equalizer.enabled)
	auto = _toolbar_button("Auto", func(): SettingsManager.equalizer.auto = not SettingsManager.equalizer.auto)
	preset = _toolbar_button("Presets", _open_presets)
	preset.size_flags_stretch_ratio = 2.0
	for button in [power, auto, preset]:
		toolbar.add_child(button)
	dialog.content.add_child(toolbar)
	curve.custom_minimum_size.y = CURVE_HEIGHT + CURVE_MARGIN * 1.5
	curve.draw.connect(_draw_curve)
	ThemeEngine.follow(curve, curve.queue_redraw)
	dialog.content.add_child(curve)
	var row := HBoxContainer.new()
	_add_column(row, "Pre", Equalizer.set_preamp)
	for index in Equalizer.FREQUENCIES.size():
		_add_column(row, Equalizer.LABELS[index], func(gain: float): Equalizer.set_gain(index, gain))
	dialog.content.add_child(row)
	var reset := dialog.add_button("Reset", Equalizer.reset, Dialog.Style.NORMAL, false)
	var done := dialog.add_button("Done", Callable(), Dialog.Style.PRIMARY)
	for pair in [[preset, sliders.front()], [sliders.back(), reset], [done, power]]:
		pair[0].focus_neighbor_right = pair[0].get_path_to(pair[1])
		pair[1].focus_neighbor_left = pair[1].get_path_to(pair[0])

func _toolbar_button(text: String, action: Callable) -> NariButton:
	var button := Dialog.text_button(text, action)
	button.custom_minimum_size = Vector2(0, 104)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.font_size = 40
	button.icon_right = true
	button.icon_size = Vector2.ONE * 44
	button.accent_on_focus = true
	return button

func _add_column(row: HBoxContainer, label: String, changed: Callable) -> void:
	var column := VBoxContainer.new()
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var readout := _label("0", 0.75)
	var band := EqualizerBand.new()
	band.value_changed.connect(func(gain: float):
		readout.text = Equalizer.format_gain(gain)
		curve.queue_redraw()
		changed.call(gain))
	band.resized.connect(curve.queue_redraw)
	for child in [readout, band, _label(label, 1.0)]:
		column.add_child(child)
	row.add_child(column)
	sliders.append(band)
	readouts.append(readout)

func _label(text: String, alpha: float) -> NariLabel:
	var label := NariLabel.new()
	label.text = text
	label.font_size = 30
	label.weight = 700
	label.modulate.a = alpha
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.clip_text = true
	return label

func _sync() -> void:
	var settings := SettingsManager.equalizer
	_paint_toggle(power, settings.enabled)
	_paint_toggle(auto, settings.auto)
	preset.text = "Preset: %s" % Equalizer.current_preset()
	var values: Array = [float(settings.preamp)] + Equalizer.gains()
	for index in sliders.size():
		sliders[index].value = values[index]
		sliders[index].dimmed = not settings.enabled
		readouts[index].text = Equalizer.format_gain(sliders[index].value)
	curve.queue_redraw()

func _paint_toggle(button: NariButton, active: bool) -> void:
	UI.paint_button(button, active)
	button.icon = CHECK if active else null

func _draw_curve() -> void:
	var area := Rect2(0.0, CURVE_MARGIN, curve.size.x, CURVE_HEIGHT)
	var alpha := 1.0 if SettingsManager.equalizer.enabled else 0.45
	var line := ThemeEngine.get_color(ThemeEngine.Colors.Foreground)
	var accent := Color(ThemeEngine.get_color(ThemeEngine.Colors.AccentBg), alpha)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(line, line.a * 0.08)
	box.set_corner_radius_all(24)
	curve.draw_style_box(box, area)
	var height := func(gain: float) -> float: return lerpf(area.position.y + 12.0, area.end.y - 12.0, inverse_lerp(Equalizer.RANGE, -Equalizer.RANGE, gain))
	for guide in [[0.0, 0.35], [sliders.front().value, 0.6]]:
		var y: float = height.call(guide[0])
		curve.draw_dashed_line(Vector2(16.0, y), Vector2(area.end.x - 16.0, y), Color(line, guide[1] * alpha), 2.0, 10.0, true, true)
	var points := PackedVector2Array()
	for band in sliders.slice(1):
		points.append(Vector2(band.get_global_rect().get_center().x - curve.global_position.x, height.call(band.value)))
	var smooth := PackedVector2Array()
	for index in points.size() - 1:
		for step in CURVE_STEPS:
			smooth.append(points[index].cubic_interpolate(points[index + 1], points[maxi(index - 1, 0)], points[mini(index + 2, points.size() - 1)], float(step) / CURVE_STEPS))
	smooth.append(points[points.size() - 1])
	curve.draw_polyline(smooth, accent, 6.0, true)
	for point in points:
		curve.draw_circle(point, 7.0, accent, true, -1.0, true)

func _open_presets() -> void:
	var menu := Dialog.menu("Presets")
	var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
	list.separation = 0
	list.follow_focus = true
	menu.content.add_child(list)
	menu.closed.connect(preset.grab_focus, CONNECT_DEFERRED)
	menu.popup()
	var names: Array = Equalizer.presets().keys()
	var current := Equalizer.current_preset()
	list.set_items(names, func(name: String) -> NariButton:
		return menu.make_choice(name, name == current, func():
			SettingsManager.equalizer.auto = false
			Equalizer.load_preset(name), preload("res://assets/icons/equalizer.svg")))
	list.custom_minimum_size.y = list.container.cell_height * minf(names.size(), ItemMenu.VISIBLE_OPTIONS)
	list.focus_item(maxi(names.find(current), 0))
	if not SettingsManager.equalizer.presets.is_empty():
		menu.add_button("Delete", _open_deletion, Dialog.Style.DANGER)
	menu.add_button("Save", func(): Dialog.ask("Save preset", current if Equalizer.is_custom(current) else "", false, Equalizer.save_preset), Dialog.Style.PRIMARY)

func _open_deletion() -> void:
	var menu := Dialog.menu("Delete a preset")
	for name: String in SettingsManager.equalizer.presets:
		menu.add_option(name, Equalizer.delete_preset.bind(name), TRASH)
	menu.add_button("Cancel")
	menu.popup()
