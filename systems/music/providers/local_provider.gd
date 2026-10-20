class_name LocalMusicProvider extends MusicProvider

var _native: Object = null
var _covers: Dictionary = {}

func _init() -> void :
	super ("local", "Local files", "Plays the music stored in the folders you select", preload("res://assets/icons/music_library.svg"), Color("9ad07a"))
	supports_folders = true
	if not Engine.has_singleton("MusicService"):
		return
	_native = Engine.get_singleton("MusicService")
	_native.connect("library_changed", library_changed.emit)
	_native.connect("library_ready", library_ready.emit)
	_native.connect("library_load_progress", library_progress.emit.unbind(1))
	_native.connect("music_folder_selected", settings_changed.emit.unbind(3))
	_native.connect("cover_ready", _on_cover_ready)

func is_configured() -> bool:
	return _native == null or not get_music_folders().is_empty()

func setup_entries() -> Array:
	return [{
		"title": "Add music folder",
		"description": "Load music from the folders that you select",
		"icon": preload("res://assets/icons/new_folder.svg"),
		"value": func():
			var count: = get_music_folders().size()
			return "%d selected" % count if count > 0 else "",
		"action": _request.bind("requestAddMusicFolder"),
	}]

func settings_entries() -> Array:
	var entries: = setup_entries()
	for folder in get_music_folders():
		var uri: = str(folder.get("uri", ""))
		entries.append({
			"title": str(folder.get("name", "Music folder")),
			"description": uri,
			"icon": preload("res://assets/icons/music_library.svg"),
			"value": func(): return "Remove",
			"action": func(): Dialog.confirm("Remove this folder?", "Remove", _remove.bind("removeMusicFolder", uri), true),
		})
	entries.append({
		"title": "Ignore a folder",
		"description": "Pick a folder to ignore its contents",
		"icon": preload("res://assets/icons/hidden_folder.svg"),
		"action": _request.bind("requestAddIgnoredMusicFolder"),
	})
	for folder in _json_array("getIgnoredMusicFoldersJson"):
		var ignored_uri: = str(folder.get("uri", ""))
		entries.append({
			"title": str(folder.get("name", "Ignored folder")),
			"description": ignored_uri,
			"icon": preload("res://assets/icons/hidden.svg"),
			"value": func(): return "Stop ignoring",
			"action": func(): Dialog.confirm("Stop ignoring this folder?", "Stop ignoring", _remove.bind("removeIgnoredMusicFolder", ignored_uri)),
		})
	return entries

func get_music_folders() -> Array:
	return _json_array("getMusicFoldersJson")

func is_loading() -> bool:
	return _native != null and _native.isMusicLibraryLoading()

func is_ready() -> bool:
	return _native != null and _native.isMusicLibraryReady()

func get_status() -> Dictionary:
	return JsonUtil.parse_dict(_native.getMusicLibraryStatusJson()) if _native else {}

func get_tracks() -> Array:
	return _json_array("getTracksJson")

func get_folder(folder_id: String) -> Dictionary:
	var tracks: = get_tracks()
	var base: = folder_id if not folder_id.is_empty() else _common_dir(tracks)
	var folders: = {}
	var here: Array = []
	for track: Dictionary in tracks:
		var dir: = _dir_of(track)
		if dir == base:
			here.append(track)
		elif dir.begins_with(base + "/"):
			var name: = dir.substr(base.length() + 1).get_slice("/", 0)
			folders[base + "/" + name] = name
	var ids: = folders.keys()
	ids.sort_custom(func(a: String, b: String): return folders[a].naturalnocasecmp_to(folders[b]) < 0)
	return {"folders": ids.map(func(id: String): return {"id": id, "name": folders[id]}), "tracks": here}

func _dir_of(track: Dictionary) -> String:
	return str(track.get("path", "")).replace("\\", "/").get_base_dir()

func _common_dir(tracks: Array) -> String:
	var common: PackedStringArray
	for index in tracks.size():
		var parts: = _dir_of(tracks[index]).split("/")
		if index == 0:
			common = parts
			continue
		var length: = 0
		while length < mini(common.size(), parts.size()) and common[length] == parts[length]:
			length += 1
		common = common.slice(0, length)
	return "/".join(common)

func get_albums() -> Array:
	return _json_array("getAlbumsJson")

func get_artists() -> Array:
	return _json_array("getArtistsJson")

func get_album(album_id: String) -> Dictionary:
	return _json_dict("getAlbumJson", album_id)

func get_artist(artist_id: String) -> Dictionary:
	return _json_dict("getArtistJson", artist_id)

func get_song(song_id: String) -> Dictionary:
	return _json_dict("getSongJson", song_id)

func get_raw_lyrics(song_id: String) -> Dictionary:
	return _json_dict("getRawLyricsJson", song_id)

func get_cover_path(kind: String, cover_id: String, thumb: bool) -> String:
	if not _native or cover_id.is_empty():
		return ""
	var path: String = _native.getCachedCover(kind, cover_id, thumb)
	if not path.is_empty():
		return path
	var key: = "%s:%s:%s" % [kind, cover_id, thumb]
	var request: Request = _covers.get(key)
	if request == null:
		request = Request.new()
		_covers[key] = request
		_native.requestCover(kind, cover_id, thumb)
	if request.finished:
		return request.result
	return await request.done

func get_playlists() -> Array:
	return _json_array("getPlaylistsJson")

func get_playlist(playlist_id: String) -> Dictionary:
	return _json_dict("getPlaylistJson", playlist_id)

func create_playlist(playlist_name: String) -> String:
	return _native.createPlaylist(playlist_name) if _native else ""

func delete_playlist(playlist_id: String) -> void :
	if _native:
		_native.deletePlaylist(playlist_id)

func rename_playlist(playlist_id: String, playlist_name: String) -> void :
	if _native:
		_native.renamePlaylist(playlist_id, playlist_name)

func add_to_playlist(playlist_id: String, song_ids: PackedStringArray) -> void :
	if _native:
		_native.addToPlaylist(playlist_id, ",".join(song_ids))

func remove_from_playlist(playlist_id: String, song_id: String) -> void :
	if _native:
		_native.removeFromPlaylist(playlist_id, song_id)

func set_playlist_image(playlist_id: String, path: String) -> void :
	if _native:
		_native.setPlaylistImage(playlist_id, path)

func _request(method: String) -> void :
	if _native:
		_native.call(method)

func _remove(method: String, uri: String) -> void :
	if _native and _native.call(method, uri):
		settings_changed.emit()

func _json_array(method: String) -> Array:
	return JsonUtil.parse_array(_native.call(method)) if _native else []

func _json_dict(method: String, argument: String) -> Dictionary:
	return JsonUtil.parse_dict(_native.call(method, argument)) if _native else {}

func _on_cover_ready(kind: String, cover_id: String, thumb: bool, path: String) -> void :
	var key: = "%s:%s:%s" % [kind, cover_id, thumb]
	var request: Request = _covers.get(key)
	if request:
		_covers.erase(key)
		request.finish(path)
