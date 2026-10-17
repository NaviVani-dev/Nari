extends CarrouselPage

const ADD_ICON := preload("res://assets/icons/add.svg")

func _ready() -> void:
	super()
	if list:
		list.hint_text = _initial_of
	MediaPlayer.playlists_changed.connect(_load)
	MediaPlayer.library_changed.connect(_load)
	_load()

func _load() -> void:
	fill(await MediaPlayer.get_playlists())

func _item_of(playlist: Dictionary) -> Dictionary:
	var playlist_id := str(playlist.get("id", ""))
	return {
		"title": str(playlist.get("name", "")),
		"subtitle": MediaPlayer.format_song_count(int(playlist.get("song_count", 0))),
		"cover_kind": MediaPlayer.COVER_PLAYLIST,
		"cover_id": MediaPlayer.playlist_cover_id(playlist),
		"pressed": func(): Main.change_page(Main.Pages.Playlist, {"playlist_id": playlist_id}),
		"menu": func(): ItemMenu.playlist(playlist),
	}

func _page_actions() -> Array:
	return [{"glyph": InputGlyphs.Glyph.X, "text": "New playlist", "icon": ADD_ICON, "action": ItemMenu.edit_playlist}]
