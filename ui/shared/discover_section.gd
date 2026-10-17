class_name DiscoverSection extends VBoxContainer

signal item_focused(item: Dictionary)
signal first_built

const KINDS := ["quick_picks", "tracks", "track_list", "albums", "artists", "playlists", "about"]
const BUILD_BUDGET_USEC := 6000

static var _budget_frame := -1
static var _budget_start := 0

@export var card_size := Vector2(340, 500)
@export var row_width := 760.0
@export var row_peek := 0.85
@export var pick_rows := 4
@export var list_limit := 5
@export var skeleton_cards := 6
@export var appear_scale := 0.9
@export var appear_time := 0.35

@onready var title: NariLabel = %Title
@onready var more: NariButton = %More
@onready var about: NariButton = %About
@onready var shelf_area: Control = %ShelfArea
@onready var shelf: ShelfScroll = %Shelf
@onready var left: NariButton = %Left
@onready var right: NariButton = %Right
@onready var row: HBoxContainer = %Row
@onready var rows: VBoxContainer = %Rows
@onready var grid_shelf: ScrollContainer = %GridShelf
@onready var grid: GridContainer = %Grid

var spec: Dictionary = {}
var items: Array = []
var skeleton := false
var settled := false
var _appeared := false
var _generation := 0

func _ready() -> void:
	add_to_group("discover_sections")
	InputGlyphs.mode_changed.connect(refresh_dim.unbind(1))
	left.pressed.connect(shelf.scroll_page_left)
	right.pressed.connect(shelf.scroll_page_right)
	more.pressed.connect(func(): (spec.get("more") as Callable).call())
	about.pressed.connect(func(): (spec.get("open", func(): pass) as Callable).call())
	resized.connect(_fit_grid)
	_fit_grid()

func _fit_grid() -> void:
	var width := minf(row_width, size.x * row_peek)
	for child: Control in grid.get_children():
		child.custom_minimum_size.x = width

func _process(_delta: float) -> void:
	if not _appeared and (skeleton or settled) and get_global_rect().intersects(get_viewport_rect()):
		_appear()
	var touch := shelf_area.is_visible_in_tree() and not InputGlyphs.navigating()
	left.visible = touch and shelf.can_scroll_left()
	right.visible = touch and shelf.can_scroll_right()

func _appear() -> void:
	_appeared = true
	pivot_offset = Vector2(0.0, size.y * 0.5)
	scale = Vector2.ONE * appear_scale
	modulate.a = 0.0
	var tween := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "scale", Vector2.ONE, appear_time)
	tween.tween_property(self, "modulate:a", 1.0, appear_time)

static func _over_budget() -> bool:
	var frame := Engine.get_process_frames()
	if frame != _budget_frame:
		_budget_frame = frame
		_budget_start = Time.get_ticks_usec()
		return false
	return Time.get_ticks_usec() - _budget_start > BUILD_BUDGET_USEC

func show_skeleton() -> void:
	if settled:
		return
	skeleton = true
	title.text = ""
	title.skeleton = true
	shelf_area.visible = true
	rows.visible = false
	grid_shelf.visible = false
	for index in skeleton_cards:
		var card := _card(Items.card("", "", "loading", "", func(): pass))
		card.focus_mode = Control.FOCUS_NONE
		card.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(card)

func show_section(section: Dictionary, found: Array) -> void:
	settled = true
	skeleton = false
	_generation += 1
	var generation := _generation
	spec = section
	items = found
	title.skeleton = false
	title.text = str(section.get("title", ""))
	var kind := str(section.get("kind", "tracks"))
	shelf_area.visible = kind in ["tracks", "albums", "artists", "playlists"]
	rows.visible = kind == "track_list"
	grid_shelf.visible = kind == "quick_picks"
	more.visible = section.get("more") is Callable
	about.visible = kind == "about"
	about.text = str(section.get("text", ""))
	if about.visible:
		first_built.emit()
	var shown := items.slice(0, list_limit) if kind == "track_list" else items
	grid.columns = maxi(1, ceili(shown.size() / float(pick_rows)))
	var target: Container = row if shelf_area.visible else rows if rows.visible else grid
	for box: Container in [row, rows, grid]:
		if box != target:
			_clear(box)
	var existing := target.get_children()
	var used := 0
	for item: Dictionary in shown:
		if _over_budget():
			await get_tree().process_frame
			if generation != _generation or not is_inside_tree():
				return
		var reuse: NariButton = existing[used] if used < existing.size() else null
		var button := _build(kind, item, reuse)
		if button == null:
			continue
		used += 1
		if button != reuse:
			if reuse:
				target.remove_child(reuse)
				reuse.queue_free()
			target.add_child(button)
			target.move_child(button, used - 1)
		button.focus_mode = Control.FOCUS_ALL
		button.mouse_filter = Control.MOUSE_FILTER_PASS
		if not button.has_meta("discover_wired"):
			button.set_meta("discover_wired", true)
			button.add_to_group("discover_items")
			button.focus_entered.connect(_dim_all)
			button.focus_exited.connect(_dim_all)
		var focused: Callable = button.get_meta("discover_focus", Callable())
		if focused.is_valid() and button.focus_entered.is_connected(focused):
			button.focus_entered.disconnect(focused)
		focused = item_focused.emit.bind(_describe(kind, item))
		button.set_meta("discover_focus", focused)
		button.focus_entered.connect(focused)
		_dim(button)
		if used == 1:
			first_built.emit()
	for leftover: Node in existing.slice(used):
		target.remove_child(leftover)
		leftover.queue_free()

func _clear(box: Container) -> void:
	for child in box.get_children():
		box.remove_child(child)
		child.queue_free()

func refresh_dim() -> void:
	for box: Container in [row, rows, grid]:
		for button: Control in box.get_children():
			_dim(button)

func _dim_all() -> void:
	get_tree().call_group("discover_sections", "refresh_dim")

func _dim(button: Control) -> void:
	var focus := get_viewport().gui_get_focus_owner()
	var active := InputGlyphs.navigating() and focus != null and focus.is_in_group("discover_items")
	button.modulate.a = FocusScroll.UNFOCUSED_OPACITY if active and button != focus else 1.0

func first_item() -> Control:
	if skeleton:
		return null
	if about.visible:
		return about
	for box: Container in [row, rows, grid]:
		if box.is_visible_in_tree() and box.get_child_count() > 0:
			return box.get_child(0)
	return null

func _build(kind: String, item: Dictionary, reuse: NariButton = null) -> NariButton:
	var id := str(item.get("id", ""))
	if id.is_empty():
		return null
	var tracks := items.filter(func(entry: Dictionary) -> bool: return not str(entry.get("id", "")).is_empty())
	match kind:
		"quick_picks", "track_list":
			var song := Items.song(item, MediaPlayer.play_tracks.bind(tracks, id), func(): ItemMenu.track(item), reuse as SongItem)
			if kind == "quick_picks":
				song.custom_minimum_size.x = minf(row_width, size.x * row_peek) if size.x > 0.0 else row_width
			return song
		"tracks":
			var cover := MediaPlayer.cover_of(item)
			return _card(Items.card(str(item.get("title", "")), str(item.get("artist", "")), cover[0], cover[1], MediaPlayer.play_tracks.bind(tracks, id), func(): ItemMenu.track(item), reuse as SongItemV, ["track", id], bool(item.get("live", false))))
		"albums":
			return _card(Items.card(str(item.get("title", "")), str(item.get("artist", "")), MediaPlayer.COVER_ALBUM, id, Main.change_page.bind(Main.Pages.Album, {"album_id": id}), func(): ItemMenu.album(item), reuse as SongItemV, ["album", id]))
		"artists":
			return _card(Items.card(str(item.get("name", "")), "", MediaPlayer.COVER_ARTIST, id, Main.change_page.bind(Main.Pages.Artist, {"artist_id": id}), func(): ItemMenu.artist(item), reuse as SongItemV, ["artist", id]))
		"playlists":
			return _card(Items.card(str(item.get("name", "")), _song_count(item), MediaPlayer.COVER_PLAYLIST, MediaPlayer.playlist_cover_id(item), Main.change_page.bind(Main.Pages.Playlist, {"playlist_id": id}), func(): ItemMenu.playlist(item), reuse as SongItemV))
	return null

func _card(card: NariButton) -> NariButton:
	card.custom_minimum_size = card_size
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return card

static func _describe(kind: String, item: Dictionary) -> Dictionary:
	var id := str(item.get("id", ""))
	match kind:
		"albums":
			return {"title": item.get("title", ""), "subtitle": item.get("artist", ""), "cover_kind": MediaPlayer.COVER_ALBUM, "cover_id": id, "like": ["album", id], "item": item}
		"artists":
			return {"title": item.get("name", ""), "subtitle": "", "cover_kind": MediaPlayer.COVER_ARTIST, "cover_id": id, "like": ["artist", id], "item": item}
		"playlists":
			return {"title": item.get("name", ""), "subtitle": _song_count(item), "cover_kind": MediaPlayer.COVER_PLAYLIST, "cover_id": MediaPlayer.playlist_cover_id(item), "item": item}
	var cover := MediaPlayer.cover_of(item)
	return {"title": item.get("title", ""), "subtitle": item.get("artist", ""), "cover_kind": cover[0], "cover_id": cover[1], "like": ["track", id], "item": item}

static func _song_count(item: Dictionary) -> String:
	return MediaPlayer.format_song_count(int(item["song_count"])) if item.has("song_count") else ""
