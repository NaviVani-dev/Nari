class_name Dialog extends CanvasLayer

signal closed
signal finished

const LAYER := 5
const FADE := 0.18
const SLIDE := 140.0
const WIDTH := 880.0
const SHADE := Color(0.0, 0.0, 0.0, 0.55)
const COVER := preload("res://ui/shared/Cover.tscn")
const CHECK := preload("res://assets/icons/check.svg")
const FOOTER_GAP := 40
const EDGE := 32.0

enum Style { NORMAL, PRIMARY, DANGER }

var content := VBoxContainer.new()
var footer := HBoxContainer.new()
var dismissable := false
var locked := false

var _dim := ColorRect.new()
var _center := CenterContainer.new()
var _panel := NariPanelContainer.new()
var _closing := false

func _init() -> void:
	layer = LAYER
	_dim.color = SHADE
	add_child(_dim)
	UI.fill(_dim)
	_dim.gui_input.connect(func(event: InputEvent):
		if dismissable and (event is InputEventScreenTouch or event is InputEventMouseButton) and not event.is_pressed():
			close())
	_dim.add_child(_center)
	UI.fill(_center)
	var panel := _panel
	panel.bg_color = ThemeEngine.Colors.Background
	panel.gradient_color = ThemeEngine.Colors.BackgroundGradient
	panel.corner_radius = 32.0
	panel.padding = 48
	panel.custom_minimum_size.x = WIDTH
	_center.add_child(panel)
	content.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_theme_constant_override("separation", 32)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 32)
	footer.hide()
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", FOOTER_GAP)
	body.add_child(content)
	body.add_child(footer)
	panel.add_child(body)
	_dim.resized.connect(_fit_width)

func _ready() -> void:
	get_tree().node_added.connect(func(node: Node):
		if _panel.is_ancestor_of(node):
			_wrap(node))
	_wrap(_panel)
	_fit_width()

func _fit_width() -> void:
	if _dim.size.x > 0.0:
		_panel.custom_minimum_size.x = minf(WIDTH, _dim.size.x - EDGE * 2.0)

func _wrap(node: Node) -> void:
	if node is FlowContainer:
		return
	if node is NariButton:
		if not node.clip_text:
			node.clip_text = true
			node.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		return
	if node is Label and not node.clip_text and node.autowrap_mode == TextServer.AUTOWRAP_OFF:
		node.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	for child in node.get_children():
		_wrap(child)

func popup() -> void:
	Main.open_dialog(self)
	_fade(1.0)
	focus.call_deferred()

func close() -> void:
	if _closing:
		return
	_closing = true
	closed.emit()
	_fade(0.0).tween_callback(func():
		finished.emit()
		queue_free())

func focus() -> void:
	var first := content.find_next_valid_focus()
	if first:
		first.grab_focus()

func _fade(target: float) -> Tween:
	_dim.modulate.a = 1.0 - target
	var tween := create_tween().set_parallel(true)
	tween.tween_property(_dim, "modulate:a", target, FADE)
	if Themes.active.has("dialog_transition"):
		Main.animate(tween, _center, Main.transition("dialog_transition"), target > 0.0, get_viewport().get_visible_rect().size.y)
		return tween.chain()
	_center.offset_top = SLIDE * target
	_center.offset_bottom = SLIDE * target
	var curve := Tween.EASE_OUT if target > 0.0 else Tween.EASE_IN
	for side in ["offset_top", "offset_bottom"]:
		tween.tween_property(_center, side, SLIDE * (1.0 - target), FADE).set_trans(Tween.TRANS_CUBIC).set_ease(curve)
	return tween.chain()

func add_button(text: String, action: Callable = Callable(), style: Style = Style.NORMAL, closes: bool = true) -> NariButton:
	var button := text_button(text, func():
		if closes:
			close()
		if action.is_valid():
			action.call())
	button.custom_minimum_size.x = 0.0
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.accent_on_focus = true
	match style:
		Style.PRIMARY:
			UI.paint_button(button, true)
			button.focus_bg_color = ThemeEngine.Colors.Foreground
			button.focus_gradient_color = ThemeEngine.Colors.Foreground
			button.focus_fg_color = ThemeEngine.Colors.Background
		Style.DANGER:
			button.bg_color = ThemeEngine.Colors.RedBg
			button.gradient_color = ThemeEngine.Colors.RedGradient
			button.fg_color = ThemeEngine.Colors.RedFg
	footer.add_child(button)
	footer.show()
	return button

func add_option(text: String, action: Callable, leading: Texture2D = null) -> NariButton:
	var button := make_option(text, action, leading)
	content.add_child(button)
	return button

func make_option(text: String, action: Callable, leading: Texture2D = null) -> NariButton:
	var button := NariButton.new()
	button.text = text
	button.font_size = 48
	button.font_weight = 600
	button.corner_radius = 32.0
	button.padding_left = 40
	button.custom_minimum_size = Vector2(0, 120)
	button.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	var mark: Icon = _leading_icon(button, leading) if leading else null
	var paint := func(selected: bool):
		button.bg_color = ThemeEngine.Colors.AccentBg if selected else ThemeEngine.Colors.Transparent
		button.gradient_color = ThemeEngine.Colors.AccentGradient if selected else ThemeEngine.Colors.Transparent
		button.fg_color = ThemeEngine.Colors.AccentFg if selected else ThemeEngine.Colors.Foreground
		if mark:
			mark.color = button.fg_color
	paint.call(false)
	button.focus_entered.connect(paint.bind(true))
	button.focus_exited.connect(paint.bind(false))
	button.pressed.connect(func():
		close()
		if action.is_valid():
			action.call())
	return button

func _leading_icon(button: NariButton, texture: Texture2D) -> Icon:
	var mark := Icon.new()
	mark.texture = texture
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	mark.custom_minimum_size = Vector2.ONE * 56
	mark.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.separation = 28
	button.add_leading(mark)
	return mark

func add_toggle(text: String, enabled: bool, toggled: Callable, leading: Texture2D = null) -> NariButton:
	var button := make_toggle(text, enabled, toggled, leading)
	content.add_child(button)
	return button

func make_toggle(text: String, enabled: bool, toggled: Callable, leading: Texture2D = null) -> NariButton:
	var button := make_choice(text, enabled, Callable(), leading)
	for connection in button.pressed.get_connections():
		button.pressed.disconnect(connection["callable"])
	button.pressed.connect(func():
		var on := button.icon == null
		button.icon = CHECK if on else null
		toggled.call(on))
	return button

func make_choice(text: String, chosen: bool, action: Callable, leading: Texture2D = null) -> NariButton:
	var button := make_option(text, action, leading)
	button.icon_right = true
	button.icon_size = Vector2.ONE * 56
	button.padding_right = 40
	button.icon = CHECK if chosen else null
	return button

static func menu(title: String, subtitle: String = "", cover_kind: String = "", cover_id: String = "") -> Dialog:
	var dialog := Dialog.new()
	dialog.dismissable = true
	dialog.content.add_theme_constant_override("separation", 0)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 32)
	if not cover_kind.is_empty():
		var cover: Cover = COVER.instantiate()
		cover.custom_minimum_size = Vector2.ONE * 136
		cover.show_shadow = false
		cover.thumbnail = true
		header.add_child(cover)
		cover.show_cover(cover_kind, cover_id)
	var texts := VBoxContainer.new()
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	for line in [[title, 56, 700, 1.0], [subtitle, 40, 600, 0.75]]:
		if str(line[0]).is_empty():
			continue
		var label := NariLabel.new()
		label.text = line[0]
		label.font_size = line[1]
		label.weight = line[2]
		label.modulate.a = line[3]
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if cover_kind.is_empty() else HORIZONTAL_ALIGNMENT_LEFT
		label.marquee = true
		texts.add_child(label)
	header.add_child(texts)
	var spaced := MarginContainer.new()
	spaced.add_theme_constant_override("margin_bottom", 24)
	spaced.add_child(header)
	dialog.content.add_child(spaced)
	return dialog

static func busy(title: String, subtitle: String = "") -> Dialog:
	var dialog := menu(title, subtitle)
	dialog.dismissable = false
	dialog.locked = true
	return dialog

static func text_button(text: String, action: Callable) -> NariButton:
	var button := NariButton.new()
	button.text = text
	button.font_size = 46
	button.font_weight = 600
	button.corner_radius = 32.0
	button.custom_minimum_size = Vector2(360, 116)
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	button.pressed.connect(action)
	return button

static func ask(title: String, value: String, secret: bool, on_accept: Callable, accept_text: String = "Save") -> Dialog:
	var dialog := Dialog.menu(title)
	var field := NariLineEdit.new()
	field.text = value
	field.secret = secret
	field.font_size = 40
	field.bg_color = ThemeEngine.Colors.PanelBg
	field.fg_color = ThemeEngine.Colors.PanelFg
	field.custom_minimum_size = Vector2(0, 112)
	field.select_all_on_focus = true
	dialog.content.add_child(field)
	var accept := func():
		dialog.close()
		on_accept.call(field.text)
	field.text_submitted.connect(func(_text: String): accept.call())
	dialog.add_button("Cancel")
	dialog.add_button(accept_text, accept, Style.PRIMARY, false)
	dialog.popup()
	return dialog

static func confirm(message: String, accept_text: String, on_accept: Callable, danger: bool = false) -> Dialog:
	var dialog := Dialog.new()
	var notice := NariLabel.new()
	notice.text = message
	notice.font_size = 64
	notice.weight = 700
	notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dialog.content.add_child(notice)
	dialog.add_button("Cancel")
	dialog.add_button(accept_text, on_accept, Style.DANGER if danger else Style.NORMAL)
	dialog.popup()
	return dialog
