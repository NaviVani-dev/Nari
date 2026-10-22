class_name MusicProvider extends RefCounted

signal library_changed
signal library_ready(success: bool, error: String)
signal library_progress
signal settings_changed
signal reachability_changed

const QUALITIES: = {"original": "Original", "high": "High (320 kbps)", "normal": "Normal (192 kbps)", "low": "Low (128 kbps)"}
const BITRATES: = {"high": 320, "normal": 192, "low": 128}

class Request extends RefCounted:
	signal done(result: Variant)

	var finished: = false
	var result: Variant = null

	func finish(value: Variant) -> void :
		finished = true
		result = value
		done.emit(value)

var id: = ""
var display_name: = ""
var description: = ""
var icon: Texture2D
var streams: = false
var supports_quality: = false
var supports_likes: = false
var supports_folders: = false
var auto_discover: = true
var paged: = false
var reachable: = true
var http: HTTPService
var _l: Log

func _init(provider_id: String, name: String, provider_description: String, provider_icon: Texture2D, color: Color) -> void :
	id = provider_id
	display_name = name
	description = provider_description
	icon = provider_icon
	_l = Log.new(name, color)

func is_configured() -> bool:
	return true

func set_reachable(value: bool) -> void :
	if reachable != value:
		reachable = value
		reachability_changed.emit()

func media_uri(_track: Dictionary, _quality: String) -> String:
	return ""

func transcodes(quality: String) -> bool:
	return supports_quality and BITRATES.has(quality)

func setup_entries() -> Array:
	return []

func settings_entries() -> Array:
	return setup_entries()

func is_loading() -> bool:
	return false

func is_ready() -> bool:
	return true

func get_status() -> Dictionary:
	return {}

func get_tracks() -> Array:
	return []

func get_albums() -> Array:
	return []

func get_artists() -> Array:
	return []

func search(_query: String, _filters: Dictionary) -> Variant:
	return null

func get_hints(_query: String) -> Variant:
	return null

func get_genres() -> Variant:
	return null

func get_album(_album_id: String) -> Dictionary:
	return {}

func get_artist(_artist_id: String) -> Dictionary:
	return {}

func get_song(_song_id: String) -> Dictionary:
	return {}

func get_raw_lyrics(_song_id: String) -> Dictionary:
	return {}

func playable(_tracks: Array) -> Array:
	return []

func get_cover_path(_kind: String, _id: String, _thumb: bool) -> String:
	return ""

func get_folder(_folder_id: String) -> Dictionary:
	return {}

func get_playlists() -> Array:
	return []

func get_playlist(_playlist_id: String) -> Dictionary:
	return {}

func create_playlist(_playlist_name: String) -> String:
	return ""

func delete_playlist(_playlist_id: String) -> void :
	pass

func rename_playlist(_playlist_id: String, _playlist_name: String) -> void :
	pass

func add_to_playlist(_playlist_id: String, _song_ids: PackedStringArray) -> void :
	pass

func remove_from_playlist(_playlist_id: String, _song_id: String) -> void :
	pass

func set_playlist_image(_playlist_id: String, _path: String) -> void :
	pass

func get_radio(_kind: String, _id: String) -> Variant:
	return null

func get_discover() -> Variant:
	return null

func get_page(_kind: String, _context_id: String, _offset: int, _limit: int) -> Variant:
	return null

func get_liked(_kind: String) -> Variant:
	return null

func set_liked(_kind: String, _id: String, _liked: bool) -> void :
	pass
