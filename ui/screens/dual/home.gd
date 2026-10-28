extends Page

@onready var carrousel: Carrousel = %Carrousel
@onready var caption_title: NariLabel = %Title
@onready var caption_subtitle: NariLabel = %Subtitle
@onready var list: StairScroll = %List

var _entries: Array = []
var _selected: int = -1
var _caption_fade: Tween

func _ready() -> void:
	var view := HomeView.mount(carrousel, carrousel.get_parent().get_node("Caption"), caption_title, caption_subtitle)
	carrousel = view[0]
	caption_title = view[1]
	caption_subtitle = view[2]
	list.item_focused.connect(func(index: int, _item: Control): select(index))
	carrousel.picked.connect(func(index: int):
		select(index)
		list.focus_item(index))
	carrousel.activated.connect(func(index: int): _open(_entries[index]))
	_entries = HomeView.entries()

	var circles: Array[Control] = []
	for entry in _entries:
		var circle := CircleButton.new()
		circle.icon = entry["icon"]
		circle.color = entry["bg"]
		circle.gradient = entry["gradient"]
		circle.foreground = entry["fg"]
		circle.focus_mode = Control.FOCUS_NONE
		circle.mouse_filter = Control.MOUSE_FILTER_IGNORE
		circles.append(circle)
	carrousel.set_items(circles)

	list.set_items(_entries, _build_item)
	var start := clampi(focus_index, 0, _entries.size() - 1)
	select(start)
	list.focus_item(start)


func _open(entry: Dictionary) -> void:
	if entry.has("action"):
		(entry["action"] as Callable).call()
	else:
		Main.change_page(entry["page"])

func select(index: int) -> void:
	const CAPTION_FADE := Carrousel.TRAVEL_TIME * 0.3

	if index == _selected:
		return
	var first := _selected < 0
	_selected = index

	carrousel.select(index, not first)

	if _caption_fade:
		_caption_fade.kill()
	if first:
		_write_caption()
		return
	_caption_fade = UI.crossfade([caption_title, caption_subtitle], CAPTION_FADE, _write_caption)

func _write_caption() -> void:
	caption_title.text = _entries[_selected]["title"]
	caption_subtitle.text = _entries[_selected]["subtitle"]

func _build_item(entry: Dictionary) -> NariButton:
	var button := NariButton.new()
	button.text = entry["title"]
	button.icon = entry["icon"]
	button.bg_color = entry["bg"]
	button.gradient_color = entry["gradient"]
	button.fg_color = entry["fg"]
	button.icon_size = Vector2.ONE * 124
	button.padding = 34
	button.separation = 32
	button.corner_radius = 96
	button.font_size = 72
	button.font_weight = 700
	button.clip_text = true
	button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	button.custom_minimum_size = Vector2(0.0, 192)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.pressed.connect(_open.bind(entry))
	return button
