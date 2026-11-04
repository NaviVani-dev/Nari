class_name SkinMenu extends RefCounted

const CHECK := "......#/.....#./#...#../.#.#.../..#...."
const ARROW := "#.../##../###./##../#..."
const TIP_FONT := 40.0
const TIP_PADDING := 18.0
const TIP_RADIUS := 22.0

static var _hidden: Array[Node] = []
static var _holds := 0

static func veil(tree: SceneTree) -> void:
	_holds += 1
	if _holds > 1:
		return
	for node in tree.current_scene.get_children():
		if (node is CanvasItem or node is CanvasLayer) and node.get("visible"):
			node.set("visible", false)
			_hidden.append(node)

static func unveil() -> void:
	_holds = maxi(_holds - 1, 0)
	if _holds > 0:
		return
	for node in _hidden:
		if is_instance_valid(node):
			node.set("visible", true)
	_hidden.clear()

static func tooltip(text: String, host: Control) -> Control:
	var unit := host.get_tree().root.content_scale_factor / host.get_window().content_scale_factor
	var panel := NariPanelContainer.new()
	var label := NariLabel.new()
	panel.bg_color = ThemeEngine.Colors.PanelBg
	panel.gradient_color = ThemeEngine.Colors.PanelGradient
	panel.corner_radius = TIP_RADIUS * unit
	panel.padding = roundi(TIP_PADDING * unit)
	label.text = text
	label.color = ThemeEngine.Colors.PanelFg
	label.font_size = roundi(TIP_FONT * unit)
	label.weight = 700
	panel.add_child(label)
	return panel

static func tip_theme() -> Theme:
	var look := Theme.new()
	look.set_stylebox("panel", "TooltipPanel", StyleBoxEmpty.new())
	return look

static func popup(host: Control, items: Array, colors: Dictionary, font: Font, zoom: float) -> void:
	if items.is_empty():
		return
	var menu := build(items, theme(host, colors, font, zoom))
	menu.popup_hide.connect(menu.queue_free)
	host.add_child(menu)
	menu.popup(Rect2i(DisplayServer.mouse_get_position(), Vector2i.ZERO))

static func build(items: Array, look: Theme) -> PopupMenu:
	var menu := PopupMenu.new()
	var actions: Array[Callable] = []
	menu.visible = false
	menu.force_native = true
	menu.theme = look
	for item: Array in items:
		if item.is_empty():
			menu.add_separator()
		elif item[1] is Array:
			var submenu := build(item[1], look)
			menu.add_child(submenu)
			menu.add_submenu_node_item(item[0], submenu)
		else:
			if item.size() > 2:
				menu.add_check_item(item[0], actions.size())
				menu.set_item_checked(menu.item_count - 1, item[2])
			else:
				menu.add_item(item[0], actions.size())
			actions.append(item[1])
	menu.id_pressed.connect(func(id: int): actions[id].call())
	return menu

static func visuals(current: int, choose: Callable, options: Array = Visualizers.choices(), owner := -1) -> Array:
	var items: Array = []
	for option: Dictionary in options:
		var target := int(option.get("mode", owner))
		var nested: Variant = option.get("items")
		var action: Variant = option.get("action")
		if target >= 0 and nested is Array and not (nested as Array).is_empty():
			items.append([str(option.get("title", "")), visuals(current, choose, nested, target)])
		elif target >= 0:
			items.append([str(option.get("title", "")), func():
				if action is Callable and (action as Callable).is_valid():
					action.call()
				choose.call(target), bool(option.get("chosen", false)) if owner >= 0 else target == current])
	return items

static func skins(choose: Callable) -> Array:
	var current := WinampSkin.current()
	var items: Array = []
	for path in WinampSkin.choices():
		items.append([WinampSkin.label(path), choose.bind(path), path == current])
		if path == WinampSkin.BUILTIN:
			items.append([])
	items.append_array([[], ["Open skins folder", WinampSkin.open_folder]])
	return items

static func nari_colors() -> Dictionary:
	var foreground := ThemeEngine.get_color(ThemeEngine.Colors.PanelFg)
	return {"bg": ThemeEngine.get_color(ThemeEngine.Colors.PanelBg), "fg": foreground, "hover": ThemeEngine.get_color(ThemeEngine.Colors.AccentBg), "hover_fg": ThemeEngine.get_color(ThemeEngine.Colors.AccentFg), "line": Color(foreground, 0.4)}

static func theme(host: Control, colors: Dictionary, font: Font, zoom: float) -> Theme:
	var scale := zoom / host.get_window().content_scale_factor
	var thin := maxi(roundi(scale), 1)
	var look := Theme.new()
	var panel := StyleBoxFlat.new()
	var hover := StyleBoxFlat.new()
	var line := StyleBoxLine.new()
	var field := StyleBoxFlat.new()
	panel.bg_color = colors["bg"]
	panel.border_color = colors["line"]
	panel.set_border_width_all(thin)
	panel.set_content_margin_all(2 * scale)
	hover.bg_color = colors["hover"]
	field.bg_color = colors["bg"]
	field.border_color = colors["fg"]
	field.set_border_width_all(thin)
	field.set_content_margin_all(3 * scale)
	line.color = colors["line"]
	line.thickness = thin
	look.default_font_size = roundi((10.0 if font else 7.0) * scale)
	if font:
		look.default_font = font
	for type in ["PopupMenu", "AcceptDialog"]:
		look.set_stylebox("panel", type, panel)
	look.set_stylebox("hover", "PopupMenu", hover)
	for item in ["separator", "labeled_separator_left", "labeled_separator_right"]:
		look.set_stylebox(item, "PopupMenu", line)
	for state in ["normal", "focus", "read_only"]:
		look.set_stylebox(state, "LineEdit", field)
	for state in ["normal", "hover", "pressed", "focus"]:
		look.set_stylebox(state, "Button", hover if state != "normal" else field)
	for type in ["PopupMenu", "Label", "Button", "LineEdit"]:
		look.set_color("font_color", type, colors["fg"])
	for item in ["font_hover_color", "font_accelerator_color"]:
		look.set_color(item, "PopupMenu", colors["hover_fg"])
	look.set_color("font_disabled_color", "PopupMenu", colors["line"])
	look.set_color("font_separator_color", "PopupMenu", colors["fg"])
	look.set_color("font_hover_color", "Button", colors["hover_fg"])
	look.set_constant("v_separation", "PopupMenu", roundi(2 * scale))
	look.set_constant("h_separation", "PopupMenu", roundi(3 * scale))
	look.set_constant("item_start_padding", "PopupMenu", roundi(4 * scale))
	look.set_constant("item_end_padding", "PopupMenu", roundi(4 * scale))
	for icon in ["checked", "radio_checked"]:
		look.set_icon(icon, "PopupMenu", glyph(CHECK, colors["fg"], scale))
	for icon in ["unchecked", "radio_unchecked"]:
		look.set_icon(icon, "PopupMenu", glyph(".......", colors["fg"], scale))
	look.set_icon("submenu", "PopupMenu", glyph(ARROW, colors["fg"], scale))
	return look

static func glyph(rows: String, color: Color, scale: float) -> ImageTexture:
	var lines := rows.split("/")
	var image := Image.create_empty(lines[0].length(), 7, false, Image.FORMAT_RGBA8)
	for y in lines.size():
		for x in lines[y].length():
			if lines[y][x] == "#":
				image.set_pixel(x, y + (7 - lines.size()) / 2, color)
	image.resize(maxi(roundi(image.get_width() * scale), 1), maxi(roundi(7 * scale), 1), Image.INTERPOLATE_NEAREST)
	return ImageTexture.create_from_image(image)
