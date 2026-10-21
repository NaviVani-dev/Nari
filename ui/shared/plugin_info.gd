class_name PluginInfo extends Control

const WIDE_SHARE := 0.85
const MAX_WIDTH := 1600.0
const SCREEN_MARGIN := 48.0
const DIALOG_PADDING := 48.0
const ICON_SIZE := 176.0
const CLOSE_SIZE := 88.0
const CLOSE_INSET := 32.0
const INFO_LINE := preload("res://ui/shared/InfoLine.tscn")
const COVER := preload("res://ui/shared/Cover.tscn")
const ESCAPED := 0xE000
const BREAK := "\u2028"
const MONTHS := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const TEXT_SIZE := 38
const HEADINGS := {"h1": 60, "h2": 52, "h3": 44}
const PAD_SCROLL := 0.6
const PAD_SCROLL_TIME := 0.25
const SWIPE_DISTANCE := 120.0
const SWIPE_BIAS := 1.5
const FRAME_PADDING := 10
const PERMISSION_LINES := {
	"network": [preload("res://assets/icons/signal4.svg"), "Internet"],
	"clipboard": [preload("res://assets/icons/edit.svg"), "Clipboard"],
	"all": [preload("res://assets/icons/plugin.svg"), "All access"],
}
const ALL_ACCESS_TEXT := "This plugin asks for All access: it can read and change your files, run programs and reach the internet with no limits. Only allow it if you trust %s."

var id := ""
var dialog: Dialog
var source: Node
var _manifest: Dictionary
var _toggle: NariButton
var _update: NariButton
var _body := VBoxContainer.new()
var _scroll := SmoothScrollContainer.new()
var _pages: PagesContainer
var _swipe_from := Vector2.INF

static func open(plugin_id: String, from: Node = null) -> void:
	var created := Dialog.new()
	created.dismissable = true
	var info := PluginInfo.new()
	info.id = plugin_id
	info.dialog = created
	info.source = from if from else Plugins
	info._manifest = info.source.manifests.get(plugin_id, {})
	info._build()
	created.content.add_child(info)
	var link := str(info._store().get("source", ""))
	if link.begins_with("https://"):
		var view := created.add_button("View source", OS.shell_open.bind(link), Dialog.Style.NORMAL, false)
		view.icon = preload("res://assets/icons/github.svg")
	if info.source != Marketplace and not (info._is_theme() and Themes.is_builtin(plugin_id)):
		var uninstall := created.add_button("Uninstall", info._remove, Dialog.Style.DANGER, false)
		uninstall.icon = preload("res://assets/icons/delete.svg")
	if info.source != Marketplace and Marketplace.has_update(plugin_id):
		info._update = created.add_button("Update", info._get_from_marketplace, Dialog.Style.NORMAL, false)
		info._update.icon = preload("res://assets/icons/download.svg")
	info._toggle = created.add_button("Enable", info._toggle_plugin, Dialog.Style.PRIMARY, false)
	for button: NariButton in created.footer.get_children():
		button.icon_size = Vector2.ONE * 52
		button.separation = 16
		button.gui_input.connect(info._pad_scroll.bind(button))
	info._paint()
	created.popup()
	info._toggle.grab_focus.call_deferred()

func _is_theme() -> bool:
	return source == Themes or (source == Marketplace and _manifest.get("kind") == "themes")

func _store() -> Dictionary:
	var store: Variant = _manifest.get("store", {})
	return store if store is Dictionary else {}

func _build() -> void:
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_scroll.allow_horizontal_scroll = false
	_scroll.follow_focus = true
	add_child(_scroll)
	UI.fill(_scroll)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 40)
	_scroll.add_child(_body)
	_body.add_child(_header())
	_body.add_child(_text(str(_manifest.get("description", "No description")), 42, 500, 0.85))
	var shots: PackedStringArray = source.screenshot_sources(id)
	if not shots.is_empty():
		_body.add_child(_gallery(shots))
	if source == Marketplace:
		var slot := VBoxContainer.new()
		_body.add_child(slot)
		_show_readme(slot)
	else:
		var readme := FileAccess.get_file_as_string(str(_manifest["path"]).path_join("README.md")) if _manifest.has("path") else ""
		if not readme.is_empty():
			_body.add_child(_readme(readme))
	if not _is_theme():
		_body.add_child(_warning(_permissions_text()))
	_body.minimum_size_changed.connect(_fit)
	var close := NariButton.new()
	close.icon = preload("res://assets/icons/close.svg")
	close.icon_size = Vector2.ONE * 60
	close.flat = true
	close.accent_on_focus = true
	close.fg_color = ThemeEngine.Colors.Foreground
	close.corner_radius = CLOSE_SIZE / 2.0
	close.padding = 0
	close.pressed.connect(func(): dialog.close())
	add_child(close)
	UI.anchor(close, 1.0, 0.0, 1.0, 0.0)
	close.offset_right = DIALOG_PADDING - CLOSE_INSET
	close.offset_left = close.offset_right - CLOSE_SIZE
	close.offset_top = CLOSE_INSET - DIALOG_PADDING
	close.offset_bottom = close.offset_top + CLOSE_SIZE

func _ready() -> void:
	_fit()

func _fit() -> void:
	if not is_inside_tree():
		return
	var screen := get_viewport_rect().size
	var room := screen.y - SCREEN_MARGIN * 2.0 - DIALOG_PADDING * 2.0 - dialog.footer.get_combined_minimum_size().y - Dialog.FOOTER_GAP
	custom_minimum_size = Vector2(minf(screen.x * WIDE_SHARE, MAX_WIDTH) - DIALOG_PADDING * 2.0, minf(_body.get_combined_minimum_size().y, room))

func _header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 36)
	var icon: Cover = COVER.instantiate()
	icon.custom_minimum_size = Vector2.ONE * ICON_SIZE
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.show_shadow = false
	icon.corner_radius = 48
	icon.texture = source.image_of(id)
	header.add_child(icon)
	var texts := VBoxContainer.new()
	texts.alignment = BoxContainer.ALIGNMENT_CENTER
	texts.add_theme_constant_override("separation", 12)
	texts.add_child(_text(str(_manifest.get("name", id)), 72, 800))
	texts.add_child(_info_line())
	var room := MarginContainer.new()
	room.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	room.add_theme_constant_override("margin_right", int(CLOSE_SIZE))
	room.add_child(texts)
	header.add_child(room)
	return header

func _info_line() -> Control:
	var path := str(_manifest.get("path", ""))
	var minimum := str(_manifest.get("min_version", ""))
	var entries := [
		[preload("res://assets/icons/artist.svg"), str(_manifest.get("author", ""))],
		[preload("res://assets/icons/recent.svg"), "Version %s" % _manifest["version"] if _manifest.has("version") else ""],
		[preload("res://assets/icons/date.svg"), _date(str(_store().get("updated", "")))],
		[preload("res://assets/icons/save.svg"), _size_text(path)],
		[preload("res://assets/icons/download.svg"), Marketplace.downloads_text(int(_manifest["downloads"])) if _manifest.has("downloads") else ""],
		[preload("res://assets/icons/info.svg"), str(_store().get("license", ""))],
		[preload("res://assets/icons/nari.svg"), "Nari %s+" % minimum if not minimum.is_empty() else ""],
	]
	if not _is_theme():
		for permission in Package.permissions(_manifest):
			entries.append(PERMISSION_LINES[permission])
	entries = entries.filter(func(entry: Array): return not str(entry[1]).is_empty())
	var line := HFlowContainer.new()
	line.add_theme_constant_override("h_separation", 16)
	for entry: Array in entries:
		if line.get_child_count() > 0:
			line.add_child(_text("·", 40, 600, 0.75, false))
		var item: InfoLine = INFO_LINE.instantiate()
		item.add_theme_constant_override("separation", 12)
		item.text_size = 40
		item.icon_size = 44.0
		line.add_child(item)
		item.set_line.call_deferred(entry[0], entry[1])
	return line

func _gallery(shots: PackedStringArray) -> Control:
	var gallery := VBoxContainer.new()
	gallery.add_theme_constant_override("separation", 28)
	var pages := PagesContainer.new()
	_pages = pages
	pages.side_pages = 0
	pages.padding = 0.0
	pages.resized.connect(func(): pages.custom_minimum_size.y = pages.size.x * 9.0 / 16.0)
	gallery.add_child(_frame(pages, shots.size() > 1))
	for shot in shots:
		var cover: Cover = COVER.instantiate()
		cover.corner_radius = 32
		pages.add_child(cover)
		_show_shot(cover, shot)
	if shots.size() < 2:
		return gallery
	var dots := HBoxContainer.new()
	dots.alignment = BoxContainer.ALIGNMENT_CENTER
	dots.add_theme_constant_override("separation", 16)
	for index in shots.size():
		var dot := NariButton.new()
		dot.bg_color = ThemeEngine.Colors.Foreground
		dot.gradient_color = ThemeEngine.Colors.Transparent
		dot.corner_radius = 10.0
		dot.padding = 0
		dot.pressed.connect(pages.go_to_page.bind(index))
		dots.add_child(dot)
	var paint := func(active: int):
		for index in dots.get_child_count():
			var dot: NariButton = dots.get_child(index)
			dot.custom_minimum_size = Vector2(56.0 if index == active else 20.0, 20.0)
			dot.modulate.a = 1.0 if index == active else 0.25
	pages.page_changed.connect(paint)
	paint.call(0)
	gallery.add_child(dots)
	return gallery

func _frame(pages: PagesContainer, flips: bool) -> Control:
	var frame := NariPanelContainer.new()
	frame.corner_radius = 32.0 + FRAME_PADDING
	frame.padding = FRAME_PADDING
	var paint := func(lit: bool):
		frame.bg_color = ThemeEngine.Colors.AccentBg if lit else ThemeEngine.Colors.Transparent
		frame.gradient_color = ThemeEngine.Colors.AccentGradient if lit else ThemeEngine.Colors.Transparent
	paint.call(false)
	frame.add_child(pages)
	if not flips:
		return frame
	frame.focus_mode = Control.FOCUS_ALL
	frame.focus_entered.connect(paint.bind(true))
	frame.focus_exited.connect(paint.bind(false))
	frame.gui_input.connect(func(event: InputEvent):
		var step := -1 if event.is_action_pressed("ui_left", true) else 1 if event.is_action_pressed("ui_right", true) else 0
		if step != 0:
			frame.accept_event()
			_flip(step))
	return frame

func _flip(step: int) -> void:
	_pages.go_to_page(wrapi(_pages.active_page + step, 0, _pages.get_child_count()))

func _swipe(event: InputEvent) -> void:
	var touch: bool = event is InputEventScreenTouch and event.index == 0
	var click: bool = event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not TapGesture.touch_input_seen and event.device != InputEvent.DEVICE_ID_EMULATION
	if not (touch or click):
		return
	if event.is_pressed():
		_swipe_from = event.position if _pages.is_visible_in_tree() and _pages.get_global_rect().has_point(event.position) else Vector2.INF
		return
	if _swipe_from == Vector2.INF:
		return
	var moved: Vector2 = event.position - _swipe_from
	_swipe_from = Vector2.INF
	if absf(moved.x) >= SWIPE_DISTANCE and absf(moved.x) >= absf(moved.y) * SWIPE_BIAS:
		_flip(-1 if moved.x > 0.0 else 1)

func _pad_scroll(event: InputEvent, button: Control) -> void:
	var down := event.is_action_pressed("ui_down", true)
	if not down and not event.is_action_pressed("ui_up", true):
		return
	var bar := _scroll.get_v_scroll_bar()
	if (bar.value >= bar.max_value - bar.page - 1.0) if down else (bar.value <= 1.0):
		return
	button.accept_event()
	_scroll.scroll_y_to(_scroll.pos.y + (-1.0 if down else 1.0) * _scroll.size.y * PAD_SCROLL, PAD_SCROLL_TIME)

func _input(event: InputEvent) -> void:
	if not _pages or _pages.get_child_count() < 2 or Main.input_root() != dialog:
		return
	_swipe(event)
	var step := -1 if event.is_action_pressed("previous_track") else 1 if event.is_action_pressed("next_track") else 0
	if step != 0:
		get_viewport().set_input_as_handled()
		_flip(step)

func _show_readme(slot: VBoxContainer) -> void:
	var readme: String = await Marketplace.readme(id)
	if is_instance_valid(slot) and not readme.is_empty():
		slot.add_child(_readme(readme))

func _show_shot(cover: Cover, shot: String) -> void:
	var texture: Texture2D = await source.load_screenshot(id, shot)
	if is_instance_valid(cover):
		cover.texture = texture

func _readme(markdown: String) -> RichTextLabel:
	var label := RichTextLabel.new()
	label.bbcode_enabled = true
	label.fit_content = true
	label.scroll_active = false
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.focus_mode = Control.FOCUS_NONE
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	var italic := FontVariation.new()
	italic.base_font = ThemeEngine.font_weights[500]
	italic.variation_transform = Transform2D(Vector2(1.0, 0.0), Vector2(0.2, 1.0), Vector2.ZERO)
	for font: Array in [["normal_font", ThemeEngine.font_weights[500]], ["bold_font", ThemeEngine.font_weights[700]], ["italics_font", italic], ["mono_font", ThemeEngine.font_weights[500]]]:
		label.add_theme_font_override(font[0], font[1])
		label.add_theme_font_size_override(font[0] + "_size", TEXT_SIZE)
	label.add_theme_constant_override("line_separation", 10)
	label.add_theme_constant_override("table_h_separation", 0)
	label.meta_clicked.connect(func(meta: Variant):
		if str(meta).begins_with("https://") or str(meta).begins_with("http://"):
			OS.shell_open(str(meta)))
	var paint := func():
		label.add_theme_color_override("default_color", ThemeEngine.get_color(ThemeEngine.Colors.Foreground))
		label.text = bbcode(markdown, ThemeEngine.get_color(ThemeEngine.Colors.AccentBg))
	ThemeEngine.follow(label, paint)
	paint.call()
	return label

func _permissions_text() -> String:
	var permissions := Package.permissions(_manifest)
	if source == Marketplace and not _manifest.has("permissions"):
		return "Every plugin in the marketplace was reviewed before it was published, but only turn on the ones you trust."
	if Plugins.ALL_ACCESS in permissions:
		return ALL_ACCESS_TEXT % _author()
	var reach := "and the internet" if "network" in permissions else "and can't reach the internet"
	if "clipboard" in permissions:
		reach += ", and it can read your clipboard"
	return "This plugin runs in a sandbox: it only touches its own files %s." % reach

func _author() -> String:
	var author := str(_manifest.get("author", ""))
	return author if not author.is_empty() else "whoever made it"

func _ask_all_access() -> void:
	var asking := Dialog.new()
	var title := _text("Allow All access?", 64, 800)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	asking.content.add_child(title)
	var body := _text(ALL_ACCESS_TEXT % _author(), 40, 500, 0.85)
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.custom_minimum_size.x = 1000.0
	asking.content.add_child(body)
	asking.add_button("Cancel")
	asking.add_button("Allow", func():
		Plugins.approve(id)
		SettingsManager.plugins.set_enabled(id, true)
		Plugins.scan()
		_paint(), Dialog.Style.DANGER)
	asking.popup()

func _warning(message: String) -> Control:
	var box := NariPanelContainer.new()
	box.bg_color = ThemeEngine.Colors.WarningGradient
	box.gradient_color = ThemeEngine.Colors.Transparent
	box.corner_radius = 32.0
	box.padding = 32
	box.self_modulate.a = 0.35
	box.add_child(_text(message, 38, 500))
	return box

func _text(text: String, font_size: int, weight: int, alpha: float = 1.0, wraps: bool = true) -> NariLabel:
	var label := NariLabel.new()
	label.text = text
	label.font_size = font_size
	label.weight = weight
	label.modulate.a = alpha
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if wraps else TextServer.AUTOWRAP_OFF
	return label

static func _date(iso: String) -> String:
	var parts := iso.substr(0, 10).split("-")
	if parts.size() != 3 or not parts[1].is_valid_int():
		return ""
	return "%s %d, %s" % [MONTHS[clampi(parts[1].to_int(), 1, 12) - 1], parts[2].to_int(), parts[0]]

static func _size(bytes: int) -> String:
	return "%.1f MB" % (bytes / 1048576.0) if bytes >= 1048576 else "%d KB" % ceili(bytes / 1024.0)

static func _weight(folder: String) -> int:
	var total := 0
	for file in DirAccess.get_files_at(folder):
		var opened := FileAccess.open(folder.path_join(file), FileAccess.READ)
		total += opened.get_length() if opened else 0
	for inner in DirAccess.get_directories_at(folder):
		total += _weight(folder.path_join(inner))
	return total

static func bbcode(markdown: String, link: Color) -> String:
	var heading := RegEx.create_from_string("^(#{1,6})\\s+(.*)")
	var item := RegEx.create_from_string("^\\s*([-*+]|\\d+[.)])\\s+(.*)")
	var rule := RegEx.create_from_string("^ {0,3}([-*_])( *\\1){2,} *$")
	var underline := RegEx.create_from_string("^ {0,3}(=+|-+) *$")
	var blocks: Array[Dictionary] = []
	var current := {}
	for line in markdown.replace("\r", "").split("\n"):
		var text := line.strip_edges()
		if current.get("kind") == "code":
			if text.begins_with("```"):
				current = {}
			else:
				current["lines"].append(line.replace("[", "[lb]"))
			continue
		var found := heading.search(line)
		var listed := item.search(line)
		var lined := underline.search(line)
		if line.ends_with("  ") or text.ends_with("\\") and not text.ends_with("\\\\"):
			text = text.trim_suffix("\\") + BREAK
		var kind := "p"
		if text.begins_with("```"):
			kind = "code"
		elif text.is_empty():
			current = {}
			continue
		elif lined and current.get("kind") == "p":
			current["kind"] = "h1" if lined.get_string(1).begins_with("=") else "h2"
			current["lines"] = [" ".join(current["lines"])]
			current = {}
			continue
		elif rule.search(line):
			kind = "hr"
		elif found:
			kind = "h%d" % mini(found.get_string(1).length(), 3)
			text = found.get_string(2)
		elif listed:
			kind = "ul" if listed.get_string(1) in ["-", "*", "+"] else "ol"
			text = listed.get_string(2)
		elif text.begins_with("|"):
			kind = "table"
		elif text.begins_with(">"):
			kind = "quote"
			text = text.trim_prefix(">").strip_edges()
		elif current.get("kind") == "quote":
			kind = "quote"
		if kind != current.get("kind") or kind.begins_with("h") or kind == "code":
			current = {"kind": kind, "lines": []}
			blocks.append(current)
		if kind != "code":
			current["lines"].append(text)
	var link_format := "[url=%s][color=#" + link.to_html(false) + "]%s[/color][/url]"
	var result := ""
	for block in blocks:
		var kind: String = block["kind"]
		var lines: Array = block["lines"] if kind == "code" else block["lines"].map(func(line: String): return _inline(line, link_format))
		if not result.is_empty():
			result += "\n" if result.ends_with("[/font_size]") else "\n\n"
		match kind:
			"h1", "h2", "h3":
				result += "[font_size=%d][b]%s[/b][/font_size]" % [HEADINGS[kind], lines[0]]
			"ul":
				result += "[ul]%s[/ul]" % "\n".join(lines)
			"ol":
				result += "[ol type=1]%s[/ol]" % "\n".join(lines)
			"quote":
				result += "[indent][i]%s[/i][/indent]" % " ".join(lines)
			"code":
				result += "[indent][code]%s[/code][/indent]" % "\n".join(lines)
			"table":
				result += _table(block["lines"], link_format)
			"hr":
				result += "[hr]"
			_:
				result += " ".join(lines).replace("\n ", "\n")
	return result

static func _table(rows: Array, link_format: String) -> String:
	var divider := RegEx.create_from_string("^\\|?[\\s:|-]+$")
	var cells: Array = rows.filter(func(row: String): return not divider.search(row)).map(func(row: String):
		return Array(row.trim_prefix("|").trim_suffix("|").split("|")).map(func(cell: String): return _inline(cell.strip_edges(), link_format)))
	if cells.is_empty():
		return ""
	var columns: int = cells[0].size()
	var text := "[table=%d]" % columns
	for row in cells.size():
		for column in columns:
			var cell: String = cells[row][column] if column < cells[row].size() else ""
			text += "[cell padding=0,8,48,8]%s[/cell]" % ("[b]%s[/b]" % cell if row == 0 else cell)
	return text + "[/table]"

static func _inline(text: String, link_format: String) -> String:
	for found in RegEx.create_from_string("\\\\([\\\\`*_{}\\[\\]()#+.!~|<>-])").search_all(text):
		text = text.replace(found.get_string(), char(ESCAPED + found.get_string(1).unicode_at(0)))
	text = text.replace("[", "[lb]")
	text = RegEx.create_from_string("<(https?://[^>\\s]+)>").sub(text, "[lb]$1]($1)", true)
	text = RegEx.create_from_string("!\\[lb\\]([^\\]]*)\\]\\([^)]*\\)").sub(text, "$1", true)
	for found in RegEx.create_from_string("\\[lb\\]([^\\]]+)\\]\\(([^)\\s]+)\\)").search_all(text):
		text = text.replace(found.get_string(), link_format % [found.get_string(2), found.get_string(1)])
	text = RegEx.create_from_string("`([^`]+)`").sub(text, "[code]$1[/code]", true)
	text = RegEx.create_from_string("(\\*\\*\\*|___)(.+?)\\1").sub(text, "[b][i]$2[/i][/b]", true)
	text = RegEx.create_from_string("(\\*\\*|__)(.+?)\\1").sub(text, "[b]$2[/b]", true)
	text = RegEx.create_from_string("~~(.+?)~~").sub(text, "[s]$1[/s]", true)
	text = RegEx.create_from_string("(?<![\\w*])\\*(?!\\s)([^*]+?)\\*(?![\\w*])").sub(text, "[i]$1[/i]", true)
	text = RegEx.create_from_string("(?<![\\w_])_(?!\\s)([^_]+?)_(?![\\w_])").sub(text, "[i]$1[/i]", true)
	for escaped in "\\`*_{}[]()#+.!~|<>-":
		text = text.replace(char(ESCAPED + escaped.unicode_at(0)), "[lb]" if escaped == "[" else escaped)
	return text.replace(BREAK, "\n")

func _toggle_plugin() -> void:
	if source == Marketplace:
		if Marketplace.is_installed(id) and not Marketplace.has_update(id):
			dialog.close()
			PluginInfo.open(id, Marketplace.installed_source(id))
		else:
			_get_from_marketplace()
		return
	if _is_theme():
		_toggle_theme()
		return
	if Plugins.is_marked(id) and Plugins.is_approved(id):
		SettingsManager.plugins.set_enabled(id, false)
	else:
		var problem := Plugins.enable_problem(id)
		if not problem.is_empty():
			Dialog.confirm(problem, "OK", Callable())
			return
		if not Plugins.is_approved(id):
			_ask_all_access()
			return
		SettingsManager.plugins.set_enabled(id, true)
	_paint()

func _toggle_theme() -> void:
	if Themes.active_id() == id:
		Themes.activate("")
		_paint()
		return
	var problem := Themes.apply_problem(id)
	if not problem.is_empty():
		Dialog.confirm(problem, "OK", Callable())
		return
	Themes.activate(id)
	_paint()

func _remove() -> void:
	var title := str(_manifest.get("name", id))
	Dialog.confirm("Uninstall %s?" % title, "Uninstall", func():
		dialog.close()
		source.uninstall(id), true)

func _get_from_marketplace() -> void:
	var button: NariButton = _update if _update else _toggle
	button.text = "Installing…" if not Marketplace.is_installed(id) else "Updating…"
	button.disabled = true
	var problem: String = await Marketplace.install(id)
	if not is_instance_valid(button):
		return
	if not problem.is_empty():
		button.disabled = false
		_paint()
		if _update:
			_update.text = "Update"
		Dialog.confirm(problem, "OK", Callable())
		return
	dialog.close()
	PluginInfo.open(id, Marketplace.installed_source(id))

func _store_action_text(current: bool) -> String:
	if Marketplace.is_installing(id):
		return "Updating…" if Marketplace.is_installed(id) else "Installing…"
	if Marketplace.has_update(id):
		return "Update"
	return "Open" if current else "Install"

func _size_text(path: String) -> String:
	if not path.is_empty():
		return _size(_weight(path))
	if _manifest.has("size"):
		return _size(int(_manifest["size"]))
	return ""

func _paint() -> void:
	if source == Marketplace:
		var current := Marketplace.is_installed(id) and not Marketplace.has_update(id)
		_toggle.text = _store_action_text(current)
		_toggle.disabled = Marketplace.is_installing(id)
		UI.paint_button(_toggle, not current)
		return
	var enabled: bool = Themes.active_id() == id if _is_theme() else Plugins.is_marked(id) and Plugins.is_approved(id)
	if _is_theme():
		_toggle.text = "Use default" if enabled else "Apply"
	else:
		_toggle.text = "Disable" if enabled else "Enable"
	UI.paint_button(_toggle, not enabled)
