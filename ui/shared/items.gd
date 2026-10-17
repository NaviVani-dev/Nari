class_name Items

const SONG_ITEM := preload("res://ui/shared/SongItem.tscn")
const SONG_ITEM_V := preload("res://ui/shared/SongItemV.tscn")
const SONG_ITEM_COMPACT := preload("res://ui/shared/SongItemCompact.tscn")

static func handlers(item: NariButton, on_pressed: Callable, on_menu: Callable) -> void:
	for connection in item.pressed.get_connections():
		item.pressed.disconnect(connection.callable)
	for connection in item.context_requested.get_connections():
		item.context_requested.disconnect(connection.callable)
	item.pressed.connect(on_pressed)
	if on_menu.is_valid():
		item.context_requested.connect(on_menu)

static func compact(data: Dictionary, on_pressed: Callable, on_menu: Callable = Callable(), item: SongItemCompact = null) -> SongItemCompact:
	if item == null:
		item = SONG_ITEM_COMPACT.instantiate()
	item.setup(data)
	handlers(item, on_pressed, on_menu)
	return item

static func song(data: Dictionary, on_pressed: Callable, on_menu: Callable = Callable(), item: SongItem = null) -> SongItem:
	if item == null:
		item = SONG_ITEM.instantiate()
	item.setup(data)
	handlers(item, on_pressed, on_menu)
	return item

static func row(title: String, subtitle: String, cover_kind: String, cover_id: String, on_pressed: Callable, on_menu: Callable = Callable(), item: SongItem = null, like: Array = []) -> SongItem:
	return song({"title": title, "subtitle": subtitle, "cover_kind": cover_kind, "cover_id": cover_id, "like": like}, on_pressed, on_menu, item)

static func card(title: String, subtitle: String, cover_kind: String, cover_id: String, on_pressed: Callable, on_menu: Callable = Callable(), item: SongItemV = null, like: Array = [], live: bool = false) -> SongItemV:
	if item == null:
		item = SONG_ITEM_V.instantiate()
	item.setup(title, subtitle, cover_kind, cover_id, like, live)
	handlers(item, on_pressed, on_menu)
	return item
