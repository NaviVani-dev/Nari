class_name CarrouselPage extends Page

const COVER: = preload("res://ui/shared/Cover.tscn")
const TOP_VIEWS: = {
	"circle": preload("res://ui/shared/views/CircleTop.tscn"),
	"ipod": preload("res://ui/shared/views/iPodTop.tscn"),
	"vertical": preload("res://ui/shared/views/VerticalTop.tscn"),
	"horizontal": preload("res://ui/shared/views/HorizontalTop.tscn"),
	"info": preload("res://ui/shared/views/InfoTop.tscn"),
}
const BOTTOM_VIEWS: = {
	"stair": preload("res://ui/shared/views/StairList.tscn"),
	"grid": preload("res://ui/shared/views/GridList.tscn"),
	"compact": preload("res://ui/shared/views/CompactList.tscn"),
}
const VIEW_DEFAULTS: = {
	"tracks": ["circle", "stair"],
	"albums": ["ipod", "grid"],
	"artists": ["vertical", "grid"],
	"playlists": ["ipod", "grid"],
	"folders": ["ipod", "grid"],
	"album": ["info", "stair"],
	"playlist": ["info", "stair"],
}
const INFO_PAGES: = ["album", "playlist"]
const VIEW_NAMES: = {"circle": "Circle", "ipod": "iPod", "vertical": "Vertical", "horizontal": "Horizontal", "info": "Info", "stair": "Stair", "grid": "Grid", "compact": "Compact"}
const VIEW_TABS: = {"top": "Main", "bottom": "Secondary"}
const VIEW_ICON: = preload("res://assets/icons/view_carousel.svg")
const SORT_ICON: = preload("res://assets/icons/sort.svg")
const SORT_ICONS: = {
	"": preload("res://assets/icons/music_note.svg"), "title": preload("res://assets/icons/music_note.svg"), "name": preload("res://assets/icons/music_note.svg"),
	"artist": preload("res://assets/icons/artist.svg"), "album": preload("res://assets/icons/album.svg"), "year": preload("res://assets/icons/date.svg"),
	"duration": preload("res://assets/icons/time.svg"), "date_added": preload("res://assets/icons/recent.svg"),
	"song_count": preload("res://assets/icons/queue_music.svg"), "album_count": preload("res://assets/icons/album.svg"),
}
const SORTS: = {
	"tracks": {"": "Title", "artist": "Artist", "album": "Album", "year": "Year", "duration": "Duration", "date_added": "Date added"},
	"albums": {"": "Title", "artist": "Artist", "year": "Year", "song_count": "Number of songs", "duration": "Duration", "date_added": "Date added"},
	"artists": {"": "Name", "album_count": "Number of albums", "song_count": "Number of songs"},
	"playlists": {"name": "Name", "song_count": "Number of songs", "duration": "Duration"},
	"album": {"": "Track number", "title": "Title", "artist": "Artist", "duration": "Duration"},
	"playlist": {"": "Playlist order", "title": "Title", "artist": "Artist", "album": "Album", "year": "Year", "duration": "Duration", "date_added": "Date added"},
}
const INFO_ICONS: = {
	"artist": preload("res://assets/icons/artist.svg"),
	"album": preload("res://assets/icons/album.svg"),
	"date": preload("res://assets/icons/date.svg"),
	"songs": preload("res://assets/icons/music_note.svg"),
	"duration": preload("res://assets/icons/time.svg"),
}
const TRACK_ICON: = preload("res://assets/icons/music_note.svg")
const SHUFFLE_ICON: = preload("res://assets/icons/shuffle.svg")
const PLAY_ICON: = preload("res://assets/icons/play.svg")
const OPEN_ICON: = preload("res://assets/icons/chevron_right.svg")
const OPTIONS_ICON: = preload("res://assets/icons/more.svg")
const ITEM_ICONS: = {
	"albums": preload("res://assets/icons/album.svg"),
	"artists": preload("res://assets/icons/artist.svg"),
	"playlists": preload("res://assets/icons/queue_music.svg"),
	"folders": preload("res://assets/icons/new_folder.svg"),
}
const EMPTY_MESSAGE: = preload("res://ui/shared/EmptyMessage.tscn")
const EMPTY_MESSAGES: = {
	"tracks": [preload("res://assets/icons/music_note.svg"), "No songs yet", "Add a music folder or connect a server in Settings to fill your library"],
	"albums": [preload("res://assets/icons/album.svg"), "No albums yet", "Albums show up here once your library has some music"],
	"artists": [preload("res://assets/icons/artist.svg"), "No artists yet", "Artists show up here once your library has some music"],
	"playlists": [preload("res://assets/icons/queue_music.svg"), "No playlists yet", "Make one to keep your favorite songs together"],
	"album": [preload("res://assets/icons/album.svg"), "This album is empty", "Its songs may have been moved or removed"],
	"playlist": [preload("res://assets/icons/queue_music.svg"), "This playlist is empty", "Add songs from their options menu"],
}
const CAPTION_FADE: = 0.135
const PAGE_SIZE: = 50
const PAGE_AHEAD: = 12
const LOADING: = {"__loading": true}
const SKELETON: = {"__skeleton": true}
const SKELETON_COUNT: = 12
const LOADING_COVER: = "loading"
const COUNT_NOUNS: = {"tracks": ["song", "songs"], "albums": ["album", "albums"], "artists": ["artist", "artists"], "playlists": ["playlist", "playlists"]}
const SUBTITLE_ICONS: = {
	"artists": preload("res://assets/icons/album.svg"),
	"playlists": preload("res://assets/icons/music_note.svg"),
}

@export var page_key: String = ""

var carrousel
var list
var caption_title: NariLabel
var caption_subtitle: NariLabel
var caption_downloaded: Icon
var caption_actions: HBoxContainer
var entries: Array = []

var _selected: int = -1
var _caption_fade: Tween
var _all: Array = []
var _source: Array = []
var _info_view: ItemInfo
var _info_fade: Tween
var _compact: bool = false
var _empty: EmptyMessage
var _pager: = {}
var _filled: = false
var _skeleton: = false

static func view_key(page: String, side: String) -> String:
	return "%s_%s" % [page, side]

static func view_options(page: String, side: String) -> Array:
	var carrousels: Array = TOP_VIEWS.keys().filter(func(view: String): return view != "info")
	match side:
		"bottom":
			return BOTTOM_VIEWS.keys()
		"single":
			return carrousels + (["stair", "compact"] if page in INFO_PAGES else BOTTOM_VIEWS.keys())
	return carrousels + (["info"] if page in INFO_PAGES else [])

static func view_default(page: String, side: String) -> String:
	return VIEW_DEFAULTS[page][0 if side == "top" else 1]

static func view_of(page: String, side: String) -> String:
	var fallback := view_default(page, side)
	var chosen := str(SettingsManager.get_value("views", view_key(page, side), fallback))
	return chosen if chosen in view_options(page, side) else fallback

func _view(side: String) -> String:
	var forced: Dictionary = data.get("views", {})
	return str(forced[side]) if forced.has(side) else view_of(page_key, side)

func _ready() -> void :
	if not page_key in INFO_PAGES:
		Main.set_header("", [])
	_show_skeleton.call_deferred()
	if bottom:
		_mount_top(_view("top"))
		_mount_list(_view("bottom"), bottom.find_child("ListArea", true, false))
		return
	var view: = _view("single")
	if TOP_VIEWS.has(view):
		_mount_top(view)
		carrousel.focus_mode = Control.FOCUS_ALL
		return
	_mount_list(view, top)
	if list is GridScroll:
		return
	list.max_width = UI.LIST_MAX_WIDTH
	_mount_top("info")
	UI.place_detail(top, list, _info_view)

func _mount_top(view: String) -> void:
	var top_view: Control = TOP_VIEWS[view].instantiate()
	top.add_child(top_view)
	UI.fill(top_view)
	if top_view is ItemInfo:
		_info_view = top_view
		return
	carrousel = top_view.get_node("%Carrousel")
	caption_title = top_view.get_node("%Title")
	caption_subtitle = top_view.get_node("%Artist")
	caption_downloaded = top_view.get_node("%Downloaded")
	caption_actions = top_view.get_node("%ActionBar")
	MediaPlayer.downloads.changed.connect(_write_caption.unbind(1))
	caption_title.marquee = true
	caption_subtitle.marquee = true
	carrousel.picked.connect( func(index: int):
		select(index)
		if list:
			list.focus_item(index))
	carrousel.activated.connect( func(index: int): _entry_item(entries[index]).pressed.call())
	carrousel.context_requested.connect( func(index: int):
		var menu: Variant = _entry_item(entries[index]).get("menu")
		if menu is Callable and menu.is_valid():
			menu.call())

func _mount_list(view: String, parent: Control) -> void:
	_compact = view == "compact"
	list = BOTTOM_VIEWS[view].instantiate()
	if bottom and list is StairScroll:
		list.padding_left = 0
		list.padding_right = 0
	parent.add_child(list)
	if not parent is Container:
		UI.fill(list)
	list.item_focused.connect( func(index: int, _item: Control): select(index))

func _show_skeleton() -> void:
	if _filled or not is_inside_tree():
		return
	_skeleton = true
	_all = []
	_all.resize(SKELETON_COUNT)
	_all.fill(SKELETON)
	_refresh_actions()
	_show_entries(0)
	if _info_view and page_key in INFO_PAGES:
		_info_view.show_skeleton()

func fill(new_entries: Array) -> void :
	var previous: = history_focus() if _selected >= 0 and not _skeleton else focus_index
	var reuse: = _skeleton
	_filled = true
	_skeleton = false
	_source = new_entries
	_all = _sorted(new_entries)
	_refresh_actions()
	_show_entries(previous, reuse)
	if _info_view and page_key in INFO_PAGES:
		_info_view.show_info(_info())

func fill_paged(kind: String, context_id: String = "") -> void:
	_pager = {"kind": kind, "context": context_id, "offset": 0, "more": true, "loading": false}
	var first: = await _next_page()
	fill(first + ([LOADING] if _pager["more"] else []))

func _next_page() -> Array:
	_pager["loading"] = true
	var page: Dictionary = await MediaPlayer.get_page(_pager["kind"], _pager["context"], _pager["offset"], PAGE_SIZE)
	var items: Array = page.get("items", [])
	_pager["offset"] += items.size()
	_pager["more"] = bool(page.get("more", false)) and not items.is_empty()
	_pager["loading"] = false
	return items

func _load_more(index: int) -> void:
	if _pager.is_empty() or not _pager["more"] or _pager["loading"] or index < entries.size() - PAGE_AHEAD:
		return
	var more: = await _next_page()
	if not is_inside_tree():
		return
	var kept: = _all.filter(func(entry: Dictionary) -> bool: return not entry.has("__loading"))
	kept.append_array(more)
	if _pager["more"]:
		kept.append(LOADING)
	_all = kept
	entries = _all
	if list:
		var focused: int = list.get_selected()
		list.set_items(entries, _build_item, _bind_item, true)
		if focused >= 0:
			list.focus_item(focused)
	if carrousel:
		carrousel.grow(entries.size(), func(): return COVER.instantiate())
	_show_empty(entries.is_empty())

func _entry_item(entry: Dictionary) -> Dictionary:
	if entry.has("__skeleton"):
		return {"title": "", "subtitle": "", "cover_kind": LOADING_COVER, "cover_id": "", "pressed": func(): pass, "menu": Callable(), "loading": true, "skeleton": true}
	if entry.has("__loading"):
		return {"title": "Loading more…", "subtitle": "", "cover_kind": LOADING_COVER, "cover_id": "", "pressed": func(): pass, "menu": Callable(), "loading": true}
	return _item_of(entry)

func history_focus() -> int:
	var selected: int = list.get_selected() if list else carrousel.selected
	return selected if selected >= 0 and selected < entries.size() else 0

func focus_content() -> void:
	if list:
		list.focus_item(0)
	elif carrousel:
		carrousel.grab_focus()

func _show_entries(start: int, reuse: bool = false) -> void:
	entries = _all
	_selected = -1
	if carrousel:
		(carrousel.refill if reuse else carrousel.set_source).call(entries.size(), func(): return COVER.instantiate(), func(cover: Cover, index: int):
			var item: = _entry_item(entries[index])
			if item.has("loading"):
				cover.show_loading()
				return
			cover.show_cover(item.cover_kind, item.cover_id)
			cover.like = item.get("like", []))
	if list:
		list.set_items(entries, _build_item, _bind_item, reuse)
	_show_empty(entries.is_empty())
	if entries.is_empty():
		if caption_title:
			caption_title.text = ""
			caption_subtitle.text = ""
		return
	var first: = start if start < entries.size() else 0
	select(first)
	if list:
		list.focus_item(first)
	else:
		carrousel.grab_focus()

func _show_empty(shown: bool) -> void:
	if not _empty and shown:
		_empty = EMPTY_MESSAGE.instantiate()
		_empty.show_message(EMPTY_MESSAGES.get(page_key, EMPTY_MESSAGES.tracks))
		if not list:
			top.add_child(_empty)
		else:
			list.add_sibling(_empty)
			if not list.get_parent() is Container:
				list.item_rect_changed.connect(_match_list)
				_match_list()
	if _empty:
		_empty.visible = shown
	if _info_view and not page_key in INFO_PAGES:
		_info_view.row.visible = not shown
	_refresh_actions()

func _match_list() -> void:
	var whole: = _info_view != null and not page_key in INFO_PAGES
	for side: Side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		_empty.set_anchor(side, float(side == SIDE_RIGHT or side == SIDE_BOTTOM) if whole else list.get_anchor(side))
		_empty.set_offset(side, 0.0 if whole else list.get_offset(side))

func _build_item(entry: Dictionary, reuse: Control = null) -> Control:
	var item: = _entry_item(entry)

	if _compact:
		var numbered: bool = item.get("numbered", false)
		var compact: = {
			"id": str(item.track.get("id", "")) if item.has("track") else "",
			"title": item.title,
			"icon": ITEM_ICONS.get(page_key, TRACK_ICON),
			"number": int(item.track.get("track_number", 0)) if numbered else 0,
		}
		compact["like"] = item.get("like", [])
		compact["skeleton"] = item.has("skeleton")
		return Items.compact(compact, item.pressed, item.menu, reuse)
	if list is GridScroll:
		return Items.card(item.title, item.subtitle, item.cover_kind, item.cover_id, item.pressed, item.menu, reuse, item.get("like", []), bool(item.get("track", {}).get("live", false)))
	if item.has("track"):
		var row: = Items.song(item.track, item.pressed, item.menu, reuse)
		row.use_number = item.get("numbered", false)
		return row
	return Items.row(item.title, item.subtitle, item.cover_kind, item.cover_id, item.pressed, item.menu, reuse, item.get("like", []))

func _bind_item(item: Control, entry: Dictionary) -> void:
	_build_item(entry, item)

func _item_of(_entry: Dictionary) -> Dictionary:
	return {}

func _info() -> Dictionary:
	return {}

func _track_item(track: Dictionary, context: MediaPlayer.Context, context_id: String = "") -> Dictionary:
	var song_id: = str(track.get("id", ""))
	var cover: = MediaPlayer.cover_of(track)
	return {
		"title": str(track.get("title", "Unknown title")),
		"subtitle": str(track.get("artist", "")),
		"cover_kind": cover[0],
		"cover_id": cover[1],
		"track": track,
		"like": ["track", song_id],
		"like_item": track,
		"pressed": func():
			if _sorting():
				MediaPlayer.play_tracks(entries, song_id)
			else:
				MediaPlayer.play(song_id, context, context_id),
		"menu": func(): ItemMenu.track(track, context_id if context == MediaPlayer.Context.PLAYLIST else ""),
	}

func _actions() -> Array:
	if _skeleton or _all.is_empty() or not page_key in INFO_PAGES:
		return []
	var actions: Array = [
		{"glyph": InputGlyphs.Glyph.X, "text": "Play", "icon": PLAY_ICON, "action": _play_pressed},
		{"glyph": InputGlyphs.Glyph.RIGHT_STICK_PRESS, "text": "Shuffle", "icon": SHUFFLE_ICON, "action": _shuffle_pressed},
	]
	var more: = _more_options()
	if more.is_valid():
		actions.append({"glyph": InputGlyphs.Glyph.Y, "text": "More", "icon": OPTIONS_ICON, "action": more})
	return actions

func _page_actions() -> Array:
	if _skeleton or _all.size() < 2:
		return []
	return [{"glyph": InputGlyphs.Glyph.X, "text": "Shuffle", "icon": SHUFFLE_ICON, "action": _shuffle_pressed}]

func _subtitle() -> String:
	if _skeleton or _all.is_empty() or not COUNT_NOUNS.has(page_key):
		return ""
	var count: = _all.filter(func(entry: Dictionary) -> bool: return not entry.has("__loading")).size()
	var more: = "+" if not _pager.is_empty() and _pager["more"] else ""
	return "%d%s %s" % [count, more, COUNT_NOUNS[page_key][0 if count == 1 and more.is_empty() else 1]]

func _refresh_actions() -> void:
	var empty: = _empty != null and _empty.visible
	var bar: HBoxContainer = _empty.get_node("%ActionBar") if empty else (_info_view.actions if _info_view else caption_actions)
	if page_key in INFO_PAGES:
		Main.set_header("", [_options_action()])
		if bar:
			UI.show_actions(bar, _actions())
		else:
			Main.set_shortcuts(_actions())
		return
	var page_actions: = _page_actions()
	Main.set_header(_subtitle(), ([] if empty else page_actions) + [_options_action()])
	var actions: Array = page_actions if empty else _actions()
	if bar:
		UI.show_actions(bar, actions)
	else:
		Main.set_shortcuts(actions)

func _options_action() -> Dictionary:
	return {"glyph": InputGlyphs.Glyph.LEFT_STICK_PRESS, "icon": OPTIONS_ICON, "action": _open_options}

func _open_options() -> void:
	if _sort_options().size() < 2:
		_open_views()
		return
	var dialog: = Dialog.menu("Options")
	dialog.add_option("View type", _open_views, VIEW_ICON)
	dialog.add_option("Sort by", _open_sorts, SORT_ICON)
	dialog.popup()

func _open_views() -> void:
	var dialog: = Dialog.menu("View type")
	var tabs: = HBoxContainer.new()
	var options: = VBoxContainer.new()
	options.add_theme_constant_override("separation", 0)
	var current: Array[NariButton] = []
	var shown: = {"side": ""}
	var show_side: = func(side: String):
		if shown.side == side:
			return
		shown.side = side
		for tab: NariButton in tabs.get_children():
			UI.paint_button(tab, tab.get_meta(&"side") == side)
		for old in options.get_children():
			options.remove_child(old)
			old.queue_free()
		for view: String in view_options(page_key, side):
			var chosen: = view == view_of(page_key, side)
			var option: = dialog.make_choice(VIEW_NAMES[view], chosen, _set_view.bind(side, view), VIEW_ICON)
			options.add_child(option)
			if chosen:
				current.assign([option])
	if bottom:
		tabs.add_theme_constant_override("separation", 24)
		for side: String in VIEW_TABS:
			var tab: = Dialog.text_button(VIEW_TABS[side], show_side.bind(side))
			tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tab.set_meta(&"side", side)
			tab.focus_entered.connect(show_side.bind(side))
			tabs.add_child(tab)
		var spaced: = MarginContainer.new()
		spaced.add_theme_constant_override("margin_bottom", 24)
		spaced.add_child(tabs)
		dialog.content.add_child(spaced)
	dialog.content.add_child(options)
	show_side.call("top" if bottom else "single")
	dialog.popup()
	if not current.is_empty():
		current[0].grab_focus.call_deferred()

func _set_view(side: String, view: String) -> void:
	SettingsManager.set_value("views", view_key(page_key, side), view)
	Main.reload_page()

func _open_sorts() -> void:
	var keys: = _sort_options()
	var before: = [_sort_key(), _descending()]
	var dialog: = Dialog.menu("Sort by")
	var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
	list.separation = 0
	list.follow_focus = true
	dialog.content.add_child(list)
	var spaced: = MarginContainer.new()
	spaced.add_theme_constant_override("margin_top", 24)
	spaced.add_child(dialog.make_toggle("Descending", _descending(), func(enabled: bool):
		SettingsManager.set_value("sort", page_key + "_descending", enabled), SORT_ICON))
	dialog.content.add_child(spaced)
	dialog.popup()
	dialog.closed.connect(func():
		if [_sort_key(), _descending()] != before:
			_all = _sorted(_source)
			_show_entries(0))
	list.set_items(keys, func(key: String) -> NariButton:
		return dialog.make_choice(SORTS[page_key][key], key == _sort_key(), SettingsManager.set_value.bind("sort", page_key, key), SORT_ICONS.get(key, SORT_ICON)))
	list.custom_minimum_size.y = list.container.cell_height * minf(keys.size(), ItemMenu.VISIBLE_OPTIONS)
	list.focus_item(keys.find(_sort_key()))

func _sort_options() -> Array:
	if not _sortable():
		return []
	return SORTS[page_key].keys().filter(func(key: String) -> bool:
		return key.is_empty() or _source.any(func(entry: Dictionary) -> bool:
			var value: Variant = entry.get(key)
			return value is String and not value.is_empty() or (value is int or value is float) and value != 0))

func _sortable() -> bool:
	return SORTS.has(page_key) and _pager.is_empty()

func _sort_key() -> String:
	var sorts: Dictionary = SORTS.get(page_key, {})
	var key: = str(SettingsManager.get_value("sort", page_key, ""))
	if sorts.has(key):
		return key
	if sorts.is_empty():
		return ""
	return str(sorts.keys().front())

func _descending() -> bool:
	return bool(SettingsManager.get_value("sort", page_key + "_descending", false))

func _sorting() -> bool:
	return _sortable() and (not _sort_key().is_empty() or _descending())

func _sorted(items: Array) -> Array:
	if not _sorting():
		return items
	var key: = _sort_key()
	var direction: = -1 if _descending() else 1
	var ranked: Array = []
	for index in items.size():
		ranked.append([items[index].get(key, "") if not key.is_empty() else 0, index, items[index]])
	ranked.sort_custom(func(first: Array, second: Array) -> bool:
		var order: = _compare(first[0], second[0]) * direction
		return order < 0 if order != 0 else first[1] * direction < second[1] * direction)
	return ranked.map(func(entry: Array) -> Dictionary: return entry[2])

static func _compare(first: Variant, second: Variant) -> int:
	if first is String or second is String:
		return str(first).naturalnocasecmp_to(str(second))
	return int(signf(float(first) - float(second)))

func _more_options() -> Callable:
	return Callable()

func _play_pressed() -> void:
	pass

func _shuffle_pressed() -> void:
	pass

func _initial_of(entry: Dictionary) -> String:
	var initial: = str(_caption_of(entry)[0]).strip_edges().left(1).to_upper()
	if initial.is_empty() or (initial.to_lower() == initial.to_upper() and initial.unicode_at(0) < 128):
		return "#"
	return initial

func select(index: int) -> void :
	if index == _selected or index < 0 or index >= entries.size():
		return
	var first: = _selected < 0
	_selected = index
	_refresh_actions()
	_load_more(index)
	if _info_view and not page_key in INFO_PAGES:
		var item: = _entry_item(entries[index])
		var subtitle: Array = [] if str(item.subtitle).is_empty() else [SUBTITLE_ICONS.get(page_key, INFO_ICONS.artist), item.subtitle]
		var show_focused: = _info_view.show_skeleton if item.has("skeleton") else _info_view.show_info.bind({"title": item.title, "subtitle": subtitle, "cover_kind": item.cover_kind, "cover_id": item.cover_id})
		if _info_fade:
			_info_fade.kill()
		if first:
			_info_view.modulate.a = 1.0
			show_focused.call()
		else:
			_info_fade = UI.crossfade([_info_view], CAPTION_FADE, show_focused)
	if not carrousel:
		return
	carrousel.select(index, not first)

	if _caption_fade:
		_caption_fade.kill()
	if first:
		_write_caption()
		return
	_caption_fade = UI.crossfade([caption_subtitle.get_parent()], CAPTION_FADE, _write_caption)


func _caption_of(entry: Dictionary) -> Array:
	var item: = _entry_item(entry)
	return [item.title, item.subtitle]

func _write_caption() -> void :
	if _selected < 0 or _selected >= entries.size():
		return
	var caption: = _caption_of(entries[_selected])
	caption_title.text = caption[0]
	caption_subtitle.text = caption[1]
	var item: = _entry_item(entries[_selected])
	caption_title.skeleton = item.has("skeleton")
	caption_subtitle.skeleton = item.has("skeleton")
	caption_downloaded.visible = item.has("track") and MediaPlayer.is_downloaded(str(item.track.get("id", "")))
