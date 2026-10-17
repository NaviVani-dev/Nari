extends CarrouselPage

const ALL_RANDOM_ICON := preload("res://assets/icons/queue_music.svg")

func _ready() -> void:
	super()
	if list:
		list.hint_text = _initial_of
	MediaPlayer.library_changed.connect(_load)
	_load()

func _load() -> void:
	if MediaPlayer.is_paged():
		fill_paged("albums")
		return
	fill(await MediaPlayer.get_albums())

func _item_of(album: Dictionary) -> Dictionary:
	var album_id := str(album.get("id", ""))
	return {
		"title": str(album.get("title", "Unknown album")),
		"subtitle": str(album.get("artist", "")),
		"cover_kind": MediaPlayer.COVER_ALBUM,
		"cover_id": album_id,
		"like": ["album", album_id],
		"like_item": album,
		"pressed": func(): Main.change_page(Main.Pages.Album, {"album_id": album_id}),
		"menu": func(): ItemMenu.album(album),
	}

func _page_actions() -> Array:
	if _skeleton or _all.is_empty():
		return []
	return [
		{"glyph": InputGlyphs.Glyph.X, "text": "Play random", "icon": SHUFFLE_ICON, "action": _shuffle_pressed},
		{"glyph": InputGlyphs.Glyph.Y, "text": "Play all random", "icon": ALL_RANDOM_ICON, "action": _play_all_random},
	]

func _play_all_random() -> void:
	var ids: Array = entries.map(func(album: Dictionary) -> String: return str(album.get("id", ""))).filter(func(album_id: String) -> bool: return not album_id.is_empty())
	ids.shuffle()
	var session := -1
	for album_id: String in ids:
		var tracks: Array = (await MediaPlayer.get_album(album_id)).get("tracks", [])
		if session != -1 and session != MediaPlayer.play_session:
			return
		if tracks.is_empty():
			continue
		if session == -1:
			MediaPlayer.play_tracks(tracks, str(tracks[0].get("id", "")))
			session = MediaPlayer.play_session
		else:
			await MediaPlayer.queue_tracks(tracks)

func _shuffle_pressed() -> void:
	if entries.is_empty():
		return
	var album_id := str(entries.pick_random().get("id", ""))
	var tracks: Array = (await MediaPlayer.get_album(album_id)).get("tracks", [])
	if not tracks.is_empty():
		MediaPlayer.play(str(tracks[0].get("id", "")), MediaPlayer.Context.ALBUM, album_id)
