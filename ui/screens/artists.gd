extends CarrouselPage

func _ready() -> void:
	super()
	if list:
		list.hint_text = _initial_of
	MediaPlayer.library_changed.connect(_load)
	_load()

func _load() -> void:
	if MediaPlayer.is_paged():
		fill_paged("artists")
		return
	fill(await MediaPlayer.get_artists())

func _item_of(artist: Dictionary) -> Dictionary:
	var artist_id := str(artist.get("id", ""))
	return {
		"title": str(artist.get("name", "Unknown artist")),
		"subtitle": "%d albums · %d songs" % [int(artist.get("album_count", 0)), int(artist.get("song_count", 0))],
		"cover_kind": MediaPlayer.COVER_ARTIST,
		"cover_id": artist_id,
		"like": ["artist", artist_id],
		"like_item": artist,
		"pressed": func(): Main.change_page(Main.Pages.Artist, {"artist_id": artist_id}),
		"menu": func(): ItemMenu.artist(artist),
	}

func _shuffle_pressed() -> void:
	if entries.is_empty():
		return
	var artist = entries[randi() % entries.size()]
	MediaPlayer.play_shuffled(MediaPlayer.Context.ARTIST, str(artist.get("id", "")))
