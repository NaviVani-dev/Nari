extends Page

const SKELETONS := 6
const ICON := preload("res://assets/icons/marketplace.svg")
const SEARCH_ICON := preload("res://assets/icons/search.svg")
const RETRY_ICON := preload("res://assets/icons/repeat.svg")
const CAPTION_FADE := 0.135
const FLOAT_HEIGHT := 28.0
const FLOAT_TIME := 1.4
const GLYPH_MAX := 400.0
const CAPTION_SHARE := 0.68
const CAPTION_GAP := 0.02

@onready var search_bar: NariLineEdit = %SearchBar
@onready var grid: GridScroll = %Grid
@onready var empty: EmptyMessage = %Empty
@onready var showcase: Control = get_node_or_null("%Showcase")
@onready var glyph: Icon = get_node_or_null("%Glyph")
@onready var picture: Cover = get_node_or_null("%Picture")
@onready var caption_title: NariLabel = get_node_or_null("%Title")
@onready var caption_description: NariLabel = get_node_or_null("%Description")

var _kind := "plugins"
var _wants_edit := false
var _ids: Array = []
var _shown := "-"
var _caption_fade: Tween
var _glyph_rest := 0.0

func _ready() -> void:
	_kind = str(data.get("kind", "plugins"))
	search_bar.placeholder_text = "Search %s by name, author or what they do" % _kind
	search_bar.focus_entered.connect(func():
		if InputGlyphs.gamepad and not _wants_edit:
			search_bar.unedit.call_deferred())
	search_bar.gui_input.connect(func(event: InputEvent):
		if event.is_action_pressed("ui_accept") and not search_bar.is_editing():
			search_bar.accept_event()
			_edit())
	search_bar.text_changed.connect(_show.unbind(1))
	search_bar.text_submitted.connect(func(_text: String):
		search_bar.unedit()
		focus_content())
	if showcase:
		_float_showcase()
		grid.item_focused.connect(func(index: int, _item: Control): _describe(str(_ids[index]) if index < _ids.size() else ""))
		_describe("")
	Marketplace.index_changed.connect(_show)
	Plugins.plugins_changed.connect(_show)
	Themes.themes_changed.connect(_show)
	Marketplace.refresh()
	_show()

func focus_content() -> void:
	if not _ids.is_empty() and not str(_ids[0]).is_empty():
		grid.focus_item(0)
	else:
		search_bar.grab_focus()

func _edit() -> void:
	_wants_edit = true
	search_bar.grab_focus()
	search_bar.edit()
	_wants_edit = false

func _show() -> void:
	if not is_inside_tree():
		return
	var waiting: bool = Marketplace.manifests.is_empty() and Marketplace.loading
	var failed: bool = Marketplace.manifests.is_empty() and Marketplace.failed
	var ids: Array = []
	if waiting:
		ids.resize(SKELETONS)
		ids.fill("")
	elif not failed:
		var words := Array(search_bar.text.to_lower().split(" ", false))
		for manifest: Dictionary in Marketplace.entries(_kind):
			var text := ("%s %s %s" % [manifest.get("name", ""), manifest.get("author", ""), manifest.get("description", "")]).to_lower()
			if words.all(func(word: String) -> bool: return text.contains(word)):
				ids.append(str(manifest["id"]))
	var refresh := ids.size() == _ids.size() and not ids.is_empty() and str(_ids[0]).is_empty() == str(ids[0]).is_empty()
	_ids = ids
	grid.set_items(ids, AddonCard.create, func(card: AddonCard, id: String): card.setup(id), refresh)
	grid.visible = not ids.is_empty()
	if showcase:
		_describe(_shown if ids.has(_shown) else "", true)
	empty.visible = ids.is_empty()
	if failed:
		empty.show_message([ICON, "Couldn't reach the marketplace", "Check your connection and try again"])
	elif search_bar.text.strip_edges().is_empty():
		empty.show_message([ICON, "No %s yet" % _kind, "What people publish shows up here once it's reviewed"])
	else:
		empty.show_message([SEARCH_ICON, "Nothing matches", "Try other words or check the spelling"])
	if Main.get_page() and Main.get_page() != self:
		return
	UI.show_actions(empty.get_node("%ActionBar"), [{"glyph": InputGlyphs.Glyph.X, "text": "Try again", "icon": RETRY_ICON, "action": Marketplace.refresh.bind(true)}] if failed else [])

func _float_showcase() -> void:
	caption_title.marquee = true
	var caption: Control = caption_title.get_parent()
	showcase.resized.connect(_fit_showcase)
	caption.minimum_size_changed.connect(_fit_showcase)
	_fit_showcase()
	var bob := func(offset: float):
		glyph.offset_top = -_glyph_rest + offset
		glyph.offset_bottom = _glyph_rest + offset
	if not Main.reduce_motion:
		var floating := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		floating.tween_method(bob, -FLOAT_HEIGHT, FLOAT_HEIGHT, FLOAT_TIME)
		floating.tween_method(bob, FLOAT_HEIGHT, -FLOAT_HEIGHT, FLOAT_TIME)

func _fit_showcase() -> void:
	var caption: Control = caption_title.get_parent()
	var height := maxf(showcase.size.y, 1.0)
	var share := clampf((height - caption.get_combined_minimum_size().y) / height, 0.0, CAPTION_SHARE)
	caption.anchor_top = share
	caption.anchor_bottom = share
	var area: Control = glyph.get_parent()
	area.anchor_bottom = maxf(share - CAPTION_GAP, area.anchor_top)
	var room := minf(area.size.x, (area.anchor_bottom - area.anchor_top) * height)
	_glyph_rest = clampf(room, 0.0, GLYPH_MAX) * 0.5
	glyph.offset_left = -_glyph_rest
	glyph.offset_right = _glyph_rest
	glyph.offset_top = -_glyph_rest
	glyph.offset_bottom = _glyph_rest

func _describe(id: String, instant: bool = false) -> void:
	if id == _shown and not instant:
		return
	var first := _shown == "-"
	_shown = id
	if _caption_fade:
		_caption_fade.kill()
	if first or instant:
		showcase.modulate.a = 1.0
		_write_caption()
	else:
		_caption_fade = UI.crossfade([showcase], CAPTION_FADE, _write_caption)

func _write_caption() -> void:
	var manifest: Dictionary = Marketplace.manifests.get(_shown, {})
	picture.visible = not manifest.is_empty()
	if manifest.is_empty():
		glyph.texture = ICON
		caption_title.text = "%s marketplace" % _kind.trim_suffix("s").capitalize()
		caption_description.text = "Made by the community and reviewed before it's published"
		return
	picture.texture = Marketplace.image_of(_shown)
	glyph.texture = null
	caption_title.text = str(manifest.get("name", _shown))
	caption_description.text = str(manifest.get("description", "")).strip_edges()
	if caption_description.text.is_empty():
		caption_description.text = "by %s" % manifest.get("author", "")
