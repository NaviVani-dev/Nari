extends CarrouselPage

func _ready() -> void:
	super()
	if list:
		list.hint_text = _initial_of
	if not data.has("tracks"):
		MediaPlayer.library_changed.connect(_load)
	_load()

func _load() -> void:
	if not data.has("tracks") and MediaPlayer.is_paged():
		fill_paged("tracks")
		return
	fill(data["tracks"] if data.has("tracks") else await MediaPlayer.get_tracks())

func _item_of(track: Dictionary) -> Dictionary:
	var item := _track_item(track, MediaPlayer.Context.ALL)
	if data.has("tracks"):
		item["pressed"] = func(): MediaPlayer.play_tracks(entries, str(track.get("id", "")))
	return item

func _page_actions() -> Array:
	var actions := super()
	if data.has("tracks") and not _all.is_empty():
		actions.append({"glyph": InputGlyphs.Glyph.Y, "text": "Play all", "icon": PLAY_ICON, "action": _play_pressed})
	return actions

func _play_pressed() -> void:
	MediaPlayer.play_tracks(entries)

func _shuffle_pressed() -> void:
	if data.has("tracks"):
		MediaPlayer.play_tracks(data["tracks"], "", true)
	else:
		MediaPlayer.play_shuffled(MediaPlayer.Context.ALL)
