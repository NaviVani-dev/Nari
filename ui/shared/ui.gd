class_name UI

const ACTION_BUTTON := preload("res://ui/shared/ActionButton.tscn")
const MARGIN := 32.0
const DETAIL_SIDE_SPACE := 92.0
const LIST_MAX_WIDTH := 1360.0
const LIST_MIN_WIDTH := 900.0
const DETAIL_MIN_WIDTH := 500.0
const DETAIL_MAX_WIDTH := 760.0
const DETAIL_TALL_SHARE := 0.4
const WIDE_RATIO := 1.25
const TALL_RATIO := 0.8
const PORTRAIT_RATIO := 1.1

static func fill(control: Control) -> void:
	control.set_anchors_preset(Control.PRESET_FULL_RECT)
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0

static func anchor(control: Control, left: float, top: float, right: float, bottom: float) -> void:
	control.anchor_left = left
	control.anchor_top = top
	control.anchor_right = right
	control.anchor_bottom = bottom
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0

static func portrait(screen: Vector2) -> bool:
	return screen.y > screen.x * PORTRAIT_RATIO

static func detail_width(total: float) -> float:
	var width := minf(DETAIL_MAX_WIDTH, total - LIST_MIN_WIDTH)
	return width if width >= DETAIL_MIN_WIDTH else 0.0

static func place_detail(area: Control, list: FocusScroll, detail: Control, optional: bool = false) -> void:
	var rest := list.padding_top
	var cap := list.max_width
	var place := func():
		var ratio := area.size.x / maxf(area.size.y, 1.0)
		var beside := detail_width(area.size.x)
		var wide := ratio > TALL_RATIO and beside > 0.0
		var tall := not wide and (not optional or ratio <= TALL_RATIO)
		detail.visible = wide or tall
		list.max_width = 0.0 if wide else cap
		if wide:
			var split := beside / area.size.x
			anchor(detail, 0.0, 0.0, split, 1.0)
			anchor(list, split, 0.0, 1.0, 1.0)
		elif tall:
			var share := maxf(DETAIL_TALL_SHARE, detail.get_combined_minimum_size().y / maxf(area.size.y, 1.0))
			anchor(detail, 0.0, 0.0, 1.0, share)
			anchor(list, 0.0, share, 1.0, 1.0)
		else:
			anchor(list, 0.0, 0.0, 1.0, 1.0)
		detail.offset_left = DETAIL_SIDE_SPACE if wide else 0.0
		list.padding_top = rest
		if list is StairScroll:
			list.beside_detail = wide
	area.resized.connect(place)
	detail.minimum_size_changed.connect(place)
	place.call()

static func crossfade(nodes: Array, time: float, write: Callable) -> Tween:
	var tween: Tween = (nodes[0] as Node).create_tween().set_parallel(true)
	for node in nodes:
		tween.tween_property(node, "modulate:a", 0.0, time)
	tween.chain().tween_callback(write)
	tween.chain()
	for node in nodes:
		tween.tween_property(node, "modulate:a", 1.0, time)
	return tween

static func swap(leaving: Control, entering: Control) -> void:
	const FADE := 0.18
	const SLIDE := 140.0
	entering.modulate.a = 0.0
	entering.offset_top = SLIDE
	entering.offset_bottom = SLIDE
	entering.show()
	var tween := entering.create_tween().set_parallel(true)
	tween.tween_property(entering, "modulate:a", 1.0, FADE)
	for offset in ["offset_top", "offset_bottom"]:
		tween.tween_property(entering, offset, 0.0, FADE).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	if not leaving or leaving == entering:
		return
	tween.tween_property(leaving, "modulate:a", 0.0, FADE)
	for offset in ["offset_top", "offset_bottom"]:
		tween.tween_property(leaving, offset, SLIDE, FADE).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(func():
		leaving.hide()
		leaving.offset_top = 0.0
		leaving.offset_bottom = 0.0)

static func pager_arrows(pages: PagesContainer, previous: NariButton, next: NariButton) -> void:
	var refresh := func(active: int):
		previous.disabled = active <= 0
		next.disabled = active >= pages.get_child_count() - 1
		previous.modulate.a = 0.5 if previous.disabled else 1.0
		next.modulate.a = 0.5 if next.disabled else 1.0
	previous.pressed.connect(pages.previous_page)
	next.pressed.connect(pages.next_page)
	pages.page_changed.connect(refresh)
	refresh.call(pages.active_page)

static func show_actions(box: Container, actions: Array) -> void:
	fill_actions(box, actions)
	Main.set_shortcuts(actions)

static func fill_actions(box: Container, actions: Array, scene: PackedScene = ACTION_BUTTON) -> void:
	var buttons := box.get_children()
	for index in range(actions.size(), buttons.size()):
		box.remove_child(buttons[index])
		buttons[index].queue_free()
	for index in actions.size():
		var button: HintButton = buttons[index] if index < buttons.size() else scene.instantiate()
		if not button.is_inside_tree():
			box.add_child(button)
		button.hint = actions[index]
	box.visible = not actions.is_empty()

static func dim_unfocused(controls: Array) -> void:
	var refresh := func():
		var focused: Control = controls[0].get_viewport().gui_get_focus_owner() if controls[0].is_inside_tree() else null
		var inside := InputGlyphs.navigating() and controls.has(focused)
		for control: Control in controls:
			control.modulate.a = FocusScroll.UNFOCUSED_OPACITY if inside and control != focused else 1.0
	for control: Control in controls:
		control.focus_entered.connect(refresh)
		control.focus_exited.connect(refresh)

static func paint_button(button: NariButton, active: bool) -> void:
	button.bg_color = ThemeEngine.Colors.AccentBg if active else ThemeEngine.Colors.PanelBg
	button.gradient_color = ThemeEngine.Colors.AccentGradient if active else ThemeEngine.Colors.PanelGradient
	button.fg_color = ThemeEngine.Colors.AccentFg if active else ThemeEngine.Colors.PanelFg

static func link(control: Control, open: Callable) -> void:
	var gesture := TapGesture.new(control)
	gesture.tapped.connect(open)
	control.gui_input.connect(func(event: InputEvent):
		if gesture.feed(event):
			control.accept_event())
	if "underline" in control:
		control.mouse_entered.connect(func():
			if not TapGesture.touch_input_seen:
				control.underline = true)
		control.mouse_exited.connect(func(): control.underline = false)

static func link_current_song(title: Control, artist: Control) -> void:
	link(title, _open_current.bind(Main.Pages.Album, "album_id"))
	link(artist, _open_current.bind(Main.Pages.Artist, "artist_id"))

static func _open_current(page: Main.Pages, key: String) -> void:
	var id := str(MediaPlayer.get_current_song().get(key, ""))
	if not id.is_empty():
		Main.change_page(page, {key: id})
