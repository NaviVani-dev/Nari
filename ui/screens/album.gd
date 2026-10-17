extends CarrouselPage

var _album_id: String = ""
var _album: Dictionary = {}

func _ready() -> void:
	super()
	_album_id = str(data.get("album_id", ""))
	_album = await MediaPlayer.get_album(_album_id)
	fill(_album.get("tracks", []))

func _item_of(track: Dictionary) -> Dictionary:
	var item := _track_item(track, MediaPlayer.Context.ALBUM, _album_id)
	item.numbered = true
	return item

func _info() -> Dictionary:
	var album := _album
	var release_type := str(album.get("release_type", "")).to_lower()
	var year := int(album.get("year", 0))
	var meta: Array = []
	if not release_type.is_empty() and release_type != "album":
		meta.append([INFO_ICONS.album, release_type.capitalize()])
	if year > 0:
		meta.append([INFO_ICONS.date, str(year)])
	meta.append([INFO_ICONS.songs, MediaPlayer.format_song_count(int(album.get("song_count", 0)))])
	meta.append([INFO_ICONS.duration, MediaPlayer.format_duration(int(album.get("duration", 0)))])
	return {
		"title": str(album.get("title", "Unknown album")),
		"subtitle": [INFO_ICONS.artist, str(album.get("artist", ""))],
		"cover_kind": MediaPlayer.COVER_ALBUM,
		"cover_id": _album_id,
		"meta": meta,
	}

func _more_options() -> Callable:
	return ItemMenu.album.bind(_album, _shuffle_pressed) if not _album.is_empty() else Callable()

func _play_pressed() -> void:
	if not entries.is_empty():
		_item_of(entries[0]).pressed.call()

func _shuffle_pressed() -> void:
	MediaPlayer.play_shuffled(MediaPlayer.Context.ALBUM, _album_id)
