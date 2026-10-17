extends Page

enum Mode { GENRES, RECENT, RESULTS }

const SKELETON_ROWS := 8

const SEARCH_ICON := preload("res://assets/icons/search.svg")
const KIND_ICONS := {
	"query": preload("res://assets/icons/search.svg"),
	"track": preload("res://assets/icons/music_note.svg"),
	"album": preload("res://assets/icons/album.svg"),
	"artist": preload("res://assets/icons/artist.svg"),
}
const MESSAGES := {
	Mode.GENRES: [preload("res://assets/icons/search.svg"), "Search your favorite songs", "Find any song, album or artist in your music"],
	Mode.RECENT: [preload("res://assets/icons/time.svg"), "No recent searches", "What you search and open shows up here"],
	Mode.RESULTS: [preload("res://assets/icons/search.svg"), "No results", "Try other words or check the spelling"],
}
const GENRE_COLORS := ["Blue", "Pink", "Teal", "Orange", "Purple", "Lime", "Cyan", "Red", "Indigo", "Green", "Yellow"]
const GENRE_BUTTON := preload("res://ui/shared/GenreButton.tscn")
const RECENT_ITEM := preload("res://ui/shared/RecentItem.tscn")
const RECENT_ICON := preload("res://assets/icons/recent.svg")
const GENRE_LIMIT := 12
const RECENT_LIMIT := 12
const SEARCH_TAG := preload("res://ui/shared/SearchTag.tscn")
const TAG_PATTERN := "(?:^|\\s)(title|artist|album|playlist|date|genre):(\"[^\"]+\"|[^\\s\"]+)"
const TAG_GAP := 12

@onready var search_bar: NariLineEdit = %SearchBar
@onready var tags: HBoxContainer = %Tags
@onready var search_button: NariButton = %SearchButton
@onready var genre_scroll: ScrollContainer = %GenreScroll
@onready var genres: GridContainer = %Genres
@onready var list: StairScroll = %List
@onready var empty: EmptyMessage = %Empty
@onready var info: ItemInfo = get_node_or_null("%Info")
@onready var idle: EmptyMessage = get_node_or_null("%Idle")

var _mode := Mode.GENRES
var _rows: Array = []
var _tracks: Array = []
var _wants_edit := false
var _filters := {}
var _search_id := 0
var _tag_start := RegEx.create_from_string("(?:^|\\s)(title|artist|album|playlist|date|genre):$")
var _tag_key := ""
var _held_text := ""
var _active_chip: NariButton
var _any_tag := RegEx.create_from_string(TAG_PATTERN + "(?=\\s|$)")

func _ready() -> void:
	search_bar.focus_entered.connect(func():
		if InputGlyphs.gamepad and not _wants_edit:
			search_bar.unedit.call_deferred())
	search_bar.editing_toggled.connect(func(editing: bool):
		if editing and (_wants_edit or not InputGlyphs.gamepad) and search_bar.text.strip_edges().is_empty():
			_show(Mode.RECENT))
	search_bar.gui_input.connect(func(event: InputEvent):
		if event.is_action_pressed("ui_accept") and not search_bar.is_editing():
			search_bar.accept_event()
			_edit()
		elif event is InputEventKey and event.pressed and event.keycode == KEY_BACKSPACE and search_bar.text.is_empty():
			if not _tag_key.is_empty():
				search_bar.accept_event()
				_undo_tag()
			elif not _filters.is_empty():
				search_bar.accept_event()
				_remove_tag(_filters.keys().back()))
	search_bar.text_changed.connect(_on_text_changed)
	search_bar.text_submitted.connect(_submit.unbind(1))
	search_button.pressed.connect(_submit)
	tags.minimum_size_changed.connect(func():
		search_bar.leading_space = int(tags.get_combined_minimum_size().x) + TAG_GAP if tags.get_child_count() > 0 else 0)
	list.item_focused.connect(func(index: int, _item: Control): _describe(index))
	MediaPlayer.library_changed.connect(_load_genres)
	InputGlyphs.mode_changed.connect(_dim_genres.unbind(1))
	_load_genres()
	_show(Mode.GENRES)

func focus_content() -> void:
	if _mode == Mode.GENRES and genres.get_child_count() > 0:
		genres.get_child(0).grab_focus()
	elif not _rows.is_empty():
		list.focus_item(0)

func go_back() -> bool:
	if _mode == Mode.GENRES:
		return false
	_search_id += 1
	_reset_query({})
	search_bar.release_focus()
	_show(Mode.GENRES)
	return true

func _load_genres() -> void:
	var names: Array = (await MediaPlayer.get_genres()).slice(0, GENRE_LIMIT)
	if not is_inside_tree():
		return
	for child in genres.get_children():
		genres.remove_child(child)
		child.queue_free()
	for index in names.size():
		var button: NariButton = GENRE_BUTTON.instantiate()
		var family: String = GENRE_COLORS[index % GENRE_COLORS.size()]
		button.text = str(names[index])
		button.bg_color = ThemeEngine.Colors[family + "Bg"]
		button.gradient_color = ThemeEngine.Colors[family + "Gradient"]
		button.fg_color = ThemeEngine.Colors[family + "Fg"]
		button.pressed.connect(_search_for.bind(str(names[index])))
		button.focus_entered.connect(_dim_genres)
		button.focus_exited.connect(_dim_genres)
		genres.add_child(button)
	if _mode == Mode.GENRES:
		_show(Mode.GENRES)

func _dim_genres() -> void:
	var focused := genres.get_children().any(func(button: Control) -> bool: return button.has_focus())
	for button: Control in genres.get_children():
		button.modulate.a = FocusScroll.UNFOCUSED_OPACITY if focused and InputGlyphs.navigating() and not button.has_focus() else 1.0

func _edit() -> void:
	_wants_edit = true
	search_bar.grab_focus()
	search_bar.edit()
	_wants_edit = false
	if search_bar.text.strip_edges().is_empty():
		_show(Mode.RECENT)

func _search_for(genre: String) -> void:
	_reset_query({"genre": genre})
	_submit()

func _reset_query(filters: Dictionary, text: String = "") -> void:
	_tag_key = ""
	_held_text = ""
	_filters = filters.duplicate()
	_set_field(text)
	_refresh_tags()

func _set_field(text: String) -> void:
	search_bar.text = text
	search_bar.caret_column = text.length()

func _on_text_changed(text: String) -> void:
	if not _tag_key.is_empty():
		if text.ends_with("  "):
			_commit_tag()
		else:
			_active_chip.text = "%s: %s|" % [_tag_key, text]
		return
	var found := _tag_start.search(text)
	if found:
		_tag_key = found.get_string(1)
		_held_text = text.substr(0, found.get_start()).strip_edges()
		_set_field("")
		_refresh_tags()
		return
	if text.strip_edges().is_empty() and _filters.is_empty():
		_show(Mode.RECENT)

func _commit_tag() -> void:
	var value := search_bar.text.strip_edges()
	if not value.is_empty():
		_filters[_tag_key] = value
	_tag_key = ""
	_set_field(_held_text + (" " if not _held_text.is_empty() else ""))
	_held_text = ""
	_refresh_tags()

func _undo_tag() -> void:
	var restored := (_held_text + " " + _tag_key).strip_edges()
	_tag_key = ""
	_held_text = ""
	_set_field(restored)
	_refresh_tags()

func _take_tags(text: String, pattern: RegEx) -> String:
	var found := pattern.search(text)
	var changed := false
	while found:
		_filters[found.get_string(1)] = found.get_string(2).trim_prefix("\"").trim_suffix("\"")
		text = text.substr(0, found.get_start()) + " " + text.substr(found.get_end())
		found = pattern.search(text)
		changed = true
	if changed:
		_refresh_tags()
	return text.strip_edges(true, false)

func _refresh_tags() -> void:
	for child in tags.get_children():
		tags.remove_child(child)
		child.queue_free()
	for key: String in _filters:
		var chip: NariButton = SEARCH_TAG.instantiate()
		chip.text = "%s: %s" % [key, _filters[key]]
		chip.pressed.connect(_remove_tag.bind(key))
		tags.add_child(chip)
	search_bar.text_hidden = not _tag_key.is_empty()
	if not _tag_key.is_empty():
		_active_chip = SEARCH_TAG.instantiate()
		_active_chip.text = "%s: %s|" % [_tag_key, search_bar.text]
		_active_chip.icon = null
		_active_chip.pressed.connect(_undo_tag)
		tags.add_child(_active_chip)
	if tags.get_child_count() == 0:
		search_bar.leading_space = 0

func _remove_tag(key: String) -> void:
	_filters.erase(key)
	_refresh_tags()
	if search_bar.text.strip_edges().is_empty() and _filters.is_empty():
		_show(Mode.RECENT)

func _submit() -> void:
	if not _tag_key.is_empty():
		_commit_tag()
	var text := _take_tags(search_bar.text, _any_tag).strip_edges()
	search_bar.text = text
	if text.is_empty() and _filters.is_empty():
		return
	_remember(_query_row(text, _filters.duplicate()))
	_run_search()

func _run_search() -> void:
	_search_id += 1
	var id := _search_id
	_show_searching.call_deferred(id)
	var found: Dictionary = await MediaPlayer.search(search_bar.text.strip_edges(), _filters.duplicate())
	if not is_inside_tree() or id != _search_id:
		return
	_search_id += 1
	_tracks = found.get("tracks", [])
	_show(Mode.RESULTS, _tracks.map(_track_row) + found.get("albums", []).map(_album_row) + found.get("artists", []).map(_artist_row))

func _show_searching(id: int) -> void:
	if id != _search_id or not is_inside_tree():
		return
	var skeleton := {"kind": "skeleton", "title": "", "subtitle": "", "cover_kind": "loading", "cover_id": ""}
	var rows: Array = []
	rows.resize(SKELETON_ROWS)
	rows.fill(skeleton)
	_show(Mode.RESULTS, rows)
	empty.visible = false

func _show(mode: Mode, rows: Array = []) -> void:
	var reuse: bool = mode == Mode.RESULTS and _mode == Mode.RESULTS and not _rows.is_empty() and _rows[0].get("kind") == "skeleton"
	_mode = mode
	_rows = SettingsManager.get_value("search", "recent", []) if mode == Mode.RECENT else rows
	genre_scroll.visible = mode == Mode.GENRES
	list.visible = mode != Mode.GENRES
	if mode == Mode.RECENT:
		list.set_items(_rows, _build_recent)
	else:
		list.set_items(_rows, _build_row, func(item: SongItem, row: Dictionary): _build_row(row, item), reuse)
	empty.show_message(MESSAGES[mode])
	empty.visible = genres.get_child_count() == 0 if mode == Mode.GENRES else _rows.is_empty()
	_describe(-1)

func _describe(index: int) -> void:
	if not info:
		return
	var shown := index >= 0 and index < _rows.size()
	info.visible = shown
	idle.visible = not shown
	if shown and _rows[index].kind == "skeleton":
		info.show_skeleton()
	elif shown:
		var row: Dictionary = _rows[index]
		info.show_info({"title": row.title, "subtitle": [KIND_ICONS.get(row.kind, SEARCH_ICON), row.subtitle], "cover_kind": row.cover_kind, "cover_id": row.cover_id})

func _build_row(row: Dictionary, reuse: SongItem = null) -> SongItem:
	var menu := _menu_of(row)
	if row.kind == "track":
		return Items.song(row.source, _open.bind(row), menu, reuse)
	return Items.row(row.title, row.subtitle, row.cover_kind, row.cover_id, _open.bind(row), menu, reuse)

func _build_recent(row: Dictionary) -> RecentItem:
	var item: RecentItem = RECENT_ITEM.instantiate()
	item.setup({"title": row.title, "icon": RECENT_ICON})
	Items.handlers(item, _open.bind(row), _menu_of(row))
	item.remove_requested.connect(_forget.bind(row))
	return item

func _menu_of(row: Dictionary) -> Callable:
	match row.kind:
		"track": return ItemMenu.track.bind(row.source, "")
		"album": return ItemMenu.album.bind(row.source)
		"artist": return ItemMenu.artist.bind(row.source)
	return Callable()

func _open(row: Dictionary) -> void:
	if row.kind == "skeleton":
		return
	_remember(row)
	match row.kind:
		"query":
			_reset_query(row.get("filters", {}), str(row.get("query", row.title)))
			_run_search()
		"track":
			MediaPlayer.play_tracks(_tracks if _mode == Mode.RESULTS else [row.source], str(row.source.get("id", "")))
		"album":
			Main.change_page(Main.Pages.Album, {"album_id": str(row.source.get("id", ""))})
		"artist":
			Main.change_page(Main.Pages.Artist, {"artist_id": str(row.source.get("id", ""))})

func _remember(row: Dictionary) -> void:
	var recent := _without(row)
	recent.push_front(row)
	SettingsManager.set_value("search", "recent", recent.slice(0, RECENT_LIMIT))

func _forget(row: Dictionary) -> void:
	SettingsManager.set_value("search", "recent", _without(row))
	_show(Mode.RECENT)

func _without(row: Dictionary) -> Array:
	return SettingsManager.get_value("search", "recent", []).filter(func(old: Dictionary): return old.kind != row.kind or old.title != row.title or old.cover_id != row.cover_id)

func _query_row(text: String, filters: Dictionary) -> Dictionary:
	var words: Array = filters.keys().map(func(key: String): return "%s:%s" % [key, filters[key]])
	if not text.is_empty():
		words.append(text)
	return {"kind": "query", "title": " ".join(words), "subtitle": "Search", "cover_kind": "", "cover_id": "", "query": text, "filters": filters, "source": {}}

func _track_row(track: Dictionary) -> Dictionary:
	var cover := MediaPlayer.cover_of(track)
	return {"kind": "track", "title": str(track.get("title", "Unknown title")), "subtitle": str(track.get("artist", "")), "cover_kind": cover[0], "cover_id": cover[1], "source": track}

func _album_row(album: Dictionary) -> Dictionary:
	return {"kind": "album", "title": str(album.get("title", "Unknown album")), "subtitle": "Album · %s" % album.get("artist", ""), "cover_kind": MediaPlayer.COVER_ALBUM, "cover_id": str(album.get("id", "")), "source": album}

func _artist_row(artist: Dictionary) -> Dictionary:
	return {"kind": "artist", "title": str(artist.get("name", "Unknown artist")), "subtitle": "Artist", "cover_kind": MediaPlayer.COVER_ARTIST, "cover_id": str(artist.get("id", "")), "source": artist}
