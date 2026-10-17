extends CarrouselPage

var _playlist_id: String = ""
var _playlist: Dictionary = {}

func _ready() -> void:
	super()
	_playlist_id = str(data.get("playlist_id", ""))
	MediaPlayer.playlists_changed.connect(_load)
	MediaPlayer.library_changed.connect(_load)
	_load()

func _load() -> void:
	_playlist = await MediaPlayer.get_playlist(_playlist_id)
	if MediaPlayer.is_paged() and _playlist_id != MediaPlayer.LIKED_PLAYLIST:
		fill_paged("playlist", _playlist_id)
		return
	fill(_playlist.get("tracks", []))

func _item_of(track: Dictionary) -> Dictionary:
	return _track_item(track, MediaPlayer.Context.PLAYLIST, _playlist_id)

func _info() -> Dictionary:
	var playlist := _playlist
	return {
		"title": str(playlist.get("name", "")),
		"cover_kind": MediaPlayer.COVER_PLAYLIST,
		"cover_id": MediaPlayer.playlist_cover_id(playlist),
		"meta": [
			[INFO_ICONS.songs, MediaPlayer.format_song_count(int(playlist.get("song_count", 0)))],
			[INFO_ICONS.duration, MediaPlayer.format_duration(int(playlist.get("duration", 0)))],
		],
	}

func _more_options() -> Callable:
	return ItemMenu.playlist.bind(_playlist, _shuffle_pressed) if not _playlist.is_empty() else Callable()

func _play_pressed() -> void:
	if not entries.is_empty():
		_item_of(entries[0]).pressed.call()

func _shuffle_pressed() -> void:
	MediaPlayer.play_shuffled(MediaPlayer.Context.PLAYLIST, _playlist_id)
