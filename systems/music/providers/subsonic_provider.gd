class_name SubsonicMusicProvider extends MusicProvider

const RELATED_SIZE: = 12
const RADIO_SIZE: = 50
const CONFIG_PATH: = "user://providers/subsonic.cfg"
const COVER_DIR: = "user://providers/subsonic/covers"
const SERVER_LOGIN: = preload("res://ui/shared/ServerLogin.tscn")
const API_VERSION: = "1.16.1"
const PAGE_SIZE: = 500
const COVER_SIZE: = 720
const THUMB_SIZE: = 300
const COVER_QUALITY: = 0.9
const UNREACHABLE: = "Could not reach the server"
const PARALLEL_REQUESTS: = 8

var _server: = ""
var _user: = ""
var _token: = ""
var _salt: = ""
var _cover_ids: Dictionary = {}
var _covers: Dictionary = {}

func _init() -> void :
	super ("subsonic", "Navidrome", "Streams the music from your own Navidrome server", preload("res://assets/icons/navidrome.svg"), Color("5ec2f2"))
	streams = true
	supports_quality = true
	supports_likes = true
	supports_folders = true
	var config: = Vault.load_config(CONFIG_PATH)
	_server = str(config.get_value("server", "url", ""))
	_user = str(config.get_value("server", "user", ""))
	_token = str(config.get_value("server", "token", ""))
	_salt = str(config.get_value("server", "salt", ""))

func is_configured() -> bool:
	return not _token.is_empty()

func is_ready() -> bool:
	return is_configured()

func setup_entries() -> Array:
	return [{
		"title": "Server",
		"description": _server if is_configured() else "Sign in to your Navidrome server",
		"icon": preload("res://assets/icons/navidrome.svg"),
		"value": func(): return _user if is_configured() else "Sign in",
		"action": _open_login,
	}]

func settings_entries() -> Array:
	var entries: = setup_entries()
	if is_configured():
		entries.append({
			"title": "Sign out",
			"description": "Forget this server and its credentials",
			"icon": preload("res://assets/icons/close.svg"),
			"action": func(): Dialog.confirm("Sign out of this server?", "Sign out", sign_out, true),
		})
	return entries

func sign_in(server: String, user: String, password: String) -> String:
	server = server.strip_edges().trim_suffix("/")
	var salt: = Crypto.new().generate_random_bytes(8).hex_encode()
	var token: = (password + salt).md5_text()
	var answer: Dictionary = {}
	for address in [server] if server.contains("://") else ["https://" + server, "http://" + server]:
		answer = await _call(address, user, token, salt, "ping", {})
		server = address
		if answer.get("error") != UNREACHABLE:
			break
	if answer.has("error"):
		return str(answer["error"])
	_server = server
	_user = user
	_token = token
	_salt = salt
	_save()
	_l.log("Signed in to %s as %s" % [_server, _user])
	settings_changed.emit()
	library_changed.emit()
	return ""

func sign_out() -> void :
	_server = ""
	_user = ""
	_token = ""
	_salt = ""
	_cover_ids.clear()
	DirAccess.remove_absolute(CONFIG_PATH)
	settings_changed.emit()
	library_changed.emit()

func get_tracks() -> Array:
	var entries: = await _pages("search3", "searchResult3", "song", func(offset: int) -> Dictionary:
		return {"query": "", "songCount": PAGE_SIZE, "songOffset": offset, "albumCount": 0, "artistCount": 0})
	var tracks: = entries.map(_song)
	tracks.sort_custom(func(first: Dictionary, second: Dictionary): return first["sort_title"] < second["sort_title"])
	return tracks

func get_albums() -> Array:
	var entries: = await _pages("getAlbumList2", "albumList2", "album", func(offset: int) -> Dictionary:
		return {"type": "alphabeticalByName", "size": PAGE_SIZE, "offset": offset})
	return entries.map(_album)

func get_artists() -> Array:
	var answer: = await _api("getArtists")
	var artists: Array = []
	for index in _field(answer, "artists").get("index", []):
		for entry in index.get("artist", []):
			artists.append(_artist(entry))
	return artists

func get_album(album_id: String) -> Dictionary:
	var entry: = _field(await _api("getAlbum", {"id": album_id}), "album")
	if entry.is_empty():
		return {}
	var album: = _album(entry)
	album["tracks"] = entry.get("song", []).map(_song)
	return album

func get_folder(folder_id: String) -> Dictionary:
	var children: Array = []
	if folder_id.is_empty():
		for root in _field(await _api("getMusicFolders"), "musicFolders").get("musicFolder", []):
			children.append({"id": "root:" + str(int(root.get("id", 0))), "name": root.get("name", ""), "isDir": true})
	elif folder_id.begins_with("root:"):
		var indexes: = _field(await _api("getIndexes", {"musicFolderId": folder_id.trim_prefix("root:")}), "indexes")
		for index in indexes.get("index", []):
			children.append_array(index.get("artist", []).map(func(entry: Dictionary): return entry.merged({"isDir": true})))
		children.append_array(indexes.get("child", []))
	else:
		children = _field(await _api("getMusicDirectory", {"id": folder_id}), "directory").get("child", [])
	var folders: Array = children.filter(func(entry: Dictionary): return entry.get("isDir", false))
	var songs: Array = children.filter(func(entry: Dictionary): return not entry.get("isDir", false))
	return {
		"folders": folders.map(func(entry: Dictionary): return {"id": str(entry.get("id", "")), "name": str(entry.get("name", entry.get("title", "")))}),
		"tracks": songs.map(_song),
	}

func get_artist(artist_id: String) -> Dictionary:
	var entry: = _field(await _api("getArtist", {"id": artist_id}), "artist")
	if entry.is_empty():
		return {}
	var artist: = _artist(entry)
	var albums: Array = entry.get("album", []).map(_album)
	var album_params: Array = albums.map(func(album: Dictionary) -> Dictionary: return {"id": str(album["id"])})
	var tracks: Array = []
	for answer: Dictionary in await _api_all("getAlbum", album_params):
		tracks.append_array(_field(answer, "album").get("song", []).map(_song))
	artist["albums"] = albums
	artist["album_count"] = albums.size()
	artist["tracks"] = tracks
	artist["song_count"] = tracks.size()
	artist["duration"] = tracks.reduce(func(total: int, track: Dictionary): return total + int(track["duration"]), 0)
	artist["cover_album_id"] = str(albums[0]["id"]) if not albums.is_empty() else artist_id
	var info: = _field(await _api("getArtistInfo2", {"id": artist_id, "count": RELATED_SIZE}), "artistInfo2")
	artist["bio"] = ArtistInfo._plain(str(info.get("biography", "")))
	var similar: Variant = info.get("similarArtist", [])
	artist["related"] = (similar as Array).filter(func(entry: Variant): return entry is Dictionary).map(_artist) if similar is Array else []
	return artist

func get_song(song_id: String) -> Dictionary:
	var entry: = _field(await _api("getSong", {"id": song_id}), "song")
	return _song(entry) if not entry.is_empty() else {}

func get_radio(kind: String, item_id: String) -> Variant:
	var similar: = "similarSongs" if kind == "track" else "similarSongs2"
	var songs: Variant = _field(await _api("getSimilarSongs" if kind == "track" else "getSimilarSongs2", {"id": item_id, "count": RADIO_SIZE}), similar).get("song", [])
	return (songs as Array).map(_song) if songs is Array else null

func get_raw_lyrics(song_id: String) -> Dictionary:
	var found: Array = _field(await _api("getLyricsBySongId", {"id": song_id}), "lyricsList").get("structuredLyrics", [])
	if found.is_empty():
		return {}
	var lyrics: Dictionary = found[0]
	var synced: = bool(lyrics.get("synced", false))
	var lines: = PackedStringArray()
	for line in lyrics.get("line", []):
		var text: = str(line.get("value", ""))
		var start: = int(line.get("start", 0))
		lines.append("[%02d:%02d.%02d]%s" % [int(start / 60000.0), int(start / 1000.0) % 60, int((start % 1000) / 10.0), text] if synced else text)
	return {"text": "\n".join(lines), "format": "lrc" if synced else "txt", "source": "subsonic", "song_id": song_id}

func playable(tracks: Array) -> Array:
	return tracks.map(func(track: Dictionary) -> Dictionary:
		var song_id: = str(track.get("id", ""))
		var album_id: = str(track.get("album_id", ""))
		var cover_id: = album_id if not album_id.is_empty() else song_id
		return {
			"id": song_id,
			"title": str(track.get("title", "")),
			"artist": str(track.get("artist", "")),
			"artist_id": str(track.get("artist_id", "")),
			"album": str(track.get("album", "")),
			"album_id": album_id,
			"duration": int(track.get("duration", 0)),
			"uri": media_uri(track, SettingsManager.playback.stream_quality),
			"file_name": str(track.get("file_name", "")).get_basename() + ".mp3" if transcodes(SettingsManager.playback.stream_quality) else str(track.get("file_name", "")),
			"cover": ProjectSettings.globalize_path(_cover_file(cover_id, false)),
			"cover_url": _address(_server, _user, _token, _salt, "getCoverArt", {"id": _cover_ids.get(cover_id, cover_id), "size": COVER_SIZE}),
			"replay_gain": track.get("replay_gain"),
		})

func media_uri(track: Dictionary, quality: String) -> String:
	var params: = {"id": str(track.get("id", ""))}
	if transcodes(quality):
		params.merge({"format": "mp3", "maxBitRate": BITRATES[quality]})
	return _address(_server, _user, _token, _salt, "stream", params)

func get_cover_path(_kind: String, cover_id: String, thumb: bool) -> String:
	if not is_configured() or cover_id.is_empty():
		return ""
	var file: = _cover_file(cover_id, thumb)
	if FileAccess.file_exists(file):
		return ProjectSettings.globalize_path(file)
	if not reachable:
		return ""
	var request: Request = _covers.get(file)
	if request == null:
		request = Request.new()
		_covers[file] = request
		_download_cover(cover_id, thumb, file, request)
	if request.finished:
		return request.result
	return await request.done

func get_playlists() -> Array:
	var answer: = await _api("getPlaylists")
	return _field(answer, "playlists").get("playlist", []).map(_playlist)

func get_playlist(playlist_id: String) -> Dictionary:
	var entry: = _field(await _api("getPlaylist", {"id": playlist_id}), "playlist")
	if entry.is_empty():
		return {}
	var playlist: = _playlist(entry)
	playlist["tracks"] = entry.get("entry", []).map(_song)
	return playlist

func create_playlist(playlist_name: String) -> String:
	return str(_field(await _api("createPlaylist", {"name": playlist_name}), "playlist").get("id", ""))

func delete_playlist(playlist_id: String) -> void :
	await _api("deletePlaylist", {"id": playlist_id})

func rename_playlist(playlist_id: String, playlist_name: String) -> void :
	await _api("updatePlaylist", {"playlistId": playlist_id, "name": playlist_name})

func add_to_playlist(playlist_id: String, song_ids: PackedStringArray) -> void :
	await _api("updatePlaylist", {"playlistId": playlist_id, "songIdToAdd": Array(song_ids)})

func remove_from_playlist(playlist_id: String, song_id: String) -> void :
	var playlist: Dictionary = await get_playlist(playlist_id)
	var tracks: Array = playlist.get("tracks", [])
	var indexes: Array = range(tracks.size()).filter(func(index: int): return str(tracks[index]["id"]) == song_id)
	if not indexes.is_empty():
		await _api("updatePlaylist", {"playlistId": playlist_id, "songIndexToRemove": indexes})

func get_liked(kind: String) -> Variant:
	var answer: = _field(await _api("getStarred2"), "starred2")
	if answer.is_empty() and not reachable:
		return null
	match kind:
		"track": return answer.get("song", []).map(_song)
		"album": return answer.get("album", []).map(_album)
		"artist": return answer.get("artist", []).map(_artist)
	return null

func set_liked(kind: String, id: String, liked: bool) -> void :
	var field: String = {"track": "id", "album": "albumId", "artist": "artistId"}.get(kind, "id")
	await _api("star" if liked else "unstar", {field: id})

func _open_login() -> void :
	var dialog: = Dialog.new()
	dialog.dismissable = true
	var login: ServerLogin = SERVER_LOGIN.instantiate()
	login.url = _server
	login.user = _user
	login.submitted.connect( func(server: String, user: String, password: String):
		var error: = await sign_in(server, user, password)
		if error.is_empty():
			dialog.close()
		else:
			login.show_error(error))
	dialog.content.add_child(login)
	dialog.popup()

func _save() -> void :
	var config: = ConfigFile.new()
	config.set_value("server", "url", _server)
	config.set_value("server", "user", _user)
	config.set_value("server", "token", _token)
	config.set_value("server", "salt", _salt)
	Vault.save_config(config, CONFIG_PATH)

func _api(endpoint: String, params: Dictionary = {}) -> Dictionary:
	if not is_configured():
		return {}
	var answer: = await _call(_server, _user, _token, _salt, endpoint, params)
	set_reachable(answer.get("error") != UNREACHABLE)
	if answer.has("error"):
		_l.warn("%s failed: %s" % [endpoint, answer["error"]])
		return {}
	return answer

func _api_all(endpoint: String, params_list: Array) -> Array[Dictionary]:
	var answers: Array[Dictionary] = []
	if not is_configured() or http == null:
		return answers
	for start in range(0, params_list.size(), PARALLEL_REQUESTS):
		var urls: = PackedStringArray()
		for params: Dictionary in params_list.slice(start, start + PARALLEL_REQUESTS):
			urls.append(_address(_server, _user, _token, _salt, endpoint, params))
		for response: HTTPService.HTTPResponse in await http.request_all(urls):
			var answer: = _answer_of(response)
			set_reachable(answer.get("error") != UNREACHABLE)
			answers.append({} if answer.has("error") else answer)
	return answers

func _call(server: String, user: String, token: String, salt: String, endpoint: String, params: Dictionary) -> Dictionary:
	if http == null:
		return {"error": "The network service is not ready"}
	var response: = await http.request(_address(server, user, token, salt, endpoint, params))
	return _answer_of(response)

func _answer_of(response: HTTPService.HTTPResponse) -> Dictionary:
	if response == null or response.result != HTTPRequest.RESULT_SUCCESS:
		return {"error": UNREACHABLE}
	var body: = _field(response.body_as_dict(), "subsonic-response")
	if body.is_empty():
		return {"error": "The server answered with code %d, is it a Navidrome server?" % response.code}
	if str(body.get("status", "")) != "ok":
		return {"error": str(_field(body, "error").get("message", "Unknown error"))}
	return body

func _address(server: String, user: String, token: String, salt: String, endpoint: String, params: Dictionary) -> String:
	var values: = {"u": user, "t": token, "s": salt, "v": API_VERSION, "c": ProjectSettings.get_setting("application/config/name", "Nari"), "f": "json"}
	values.merge(params)
	var query: = PackedStringArray()
	for key in values:
		for value in values[key] if values[key] is Array else [values[key]]:
			query.append("%s=%s" % [str(key).uri_encode(), str(value).uri_encode()])
	return "%s/rest/%s?%s" % [server, endpoint, "&".join(query)]

func _pages(endpoint: String, container: String, key: String, params: Callable) -> Array:
	var found: Array = []
	while true:
		var page: Array = _field(await _api(endpoint, params.call(found.size())), container).get(key, [])
		found.append_array(page)
		if page.size() < PAGE_SIZE:
			break
	return found

func _song(entry: Dictionary) -> Dictionary:
	var song_id: = str(entry.get("id", ""))
	var album_id: = str(entry.get("albumId", ""))
	_remember_cover(album_id if not album_id.is_empty() else song_id, entry)
	var file_name: = str(entry.get("path", "")).get_file()
	if file_name.is_empty():
		file_name = "%s.%s" % [song_id, entry.get("suffix", "")]
	var gain: Variant = _field(entry, "replayGain").get("trackGain")
	return {
		"id": song_id,
		"title": str(entry.get("title", "Unknown title")),
		"sort_title": _sort_title(str(entry.get("title", ""))),
		"artist": str(entry.get("artist", "")),
		"artists": [str(entry.get("artist", ""))],
		"artist_id": str(entry.get("artistId", "")),
		"album": str(entry.get("album", "")),
		"album_id": album_id,
		"track_number": int(entry.get("track", 0)),
		"disc_number": int(entry.get("discNumber", 0)),
		"year": int(entry.get("year", 0)),
		"duration": int(entry.get("duration", 0)) * 1000,
		"genres": [str(entry["genre"])] if entry.has("genre") else [],
		"file_name": file_name,
		"mime_type": str(entry.get("contentType", "")),
		"bitrate": int(entry.get("bitRate", 0)),
		"replay_gain": float(gain) if gain != null else null,
	}

func _album(entry: Dictionary) -> Dictionary:
	var album_id: = str(entry.get("id", ""))
	_remember_cover(album_id, entry)
	var types: Array = entry.get("releaseTypes", [])
	return {
		"id": album_id,
		"title": str(entry.get("name", entry.get("title", "Unknown album"))),
		"artist": str(entry.get("artist", "")),
		"artist_id": str(entry.get("artistId", "")),
		"year": int(entry.get("year", 0)),
		"release_type": str(types[0]).to_lower() if not types.is_empty() else "album",
		"song_count": int(entry.get("songCount", 0)),
		"duration": int(entry.get("duration", 0)) * 1000,
	}

func _artist(entry: Dictionary) -> Dictionary:
	var artist_id: = str(entry.get("id", ""))
	_remember_cover(artist_id, entry)
	return {
		"id": artist_id,
		"name": str(entry.get("name", "Unknown artist")),
		"album_count": int(entry.get("albumCount", 0)),
		"song_count": 0,
		"duration": 0,
		"cover_album_id": artist_id,
	}

func _playlist(entry: Dictionary) -> Dictionary:
	var playlist_id: = str(entry.get("id", ""))
	_remember_cover(playlist_id, entry)
	return {
		"id": playlist_id,
		"name": str(entry.get("name", "")),
		"song_count": int(entry.get("songCount", 0)),
		"duration": int(entry.get("duration", 0)) * 1000,
		"modified": str(entry.get("changed", "")).hash(),
		"cover_album_ids": [playlist_id],
		"image": "",
	}

func _remember_cover(cover_id: String, entry: Dictionary) -> void :
	if not cover_id.is_empty() and entry.has("coverArt"):
		_cover_ids[cover_id] = str(entry["coverArt"])

func _cover_file(cover_id: String, thumb: bool) -> String:
	return "%s/%s_%d.jpg" % [COVER_DIR, cover_id.validate_filename(), THUMB_SIZE if thumb else COVER_SIZE]

func _download_cover(cover_id: String, thumb: bool, file: String, request: Request) -> void :
	var params: = {"id": _cover_ids.get(cover_id, cover_id)}
	if thumb:
		params["size"] = THUMB_SIZE
	var response: = await http.request(_address(_server, _user, _token, _salt, "getCoverArt", params))
	var path: = ""
	if response and response.succeeded():
		path = await store_cover(response.body, file, THUMB_SIZE if thumb else COVER_SIZE, not thumb)
	_covers.erase(file)
	request.finish(path)

static func store_cover(bytes: PackedByteArray, file: String, size: int, keep_animation: bool) -> String:
	DirAccess.make_dir_recursive_absolute(file.get_base_dir())
	var moving: = file.get_basename() + ".anim"
	var native: = ClassDB.class_exists("NariAnimation")
	var animated: bool = native and ClassDB.class_call_static("NariAnimation", "is_animated", bytes)
	var image: Image = null if animated else await Worker.run(_fit.bind(bytes, size))
	if image and image.save_jpg(file, COVER_QUALITY) == OK:
		if FileAccess.file_exists(moving):
			DirAccess.remove_absolute(moving)
		return ProjectSettings.globalize_path(file)
	var output: = FileAccess.open(moving, FileAccess.WRITE) if native else null
	if output == null:
		return ""
	output.store_buffer(bytes)
	output.close()
	var saved: bool = ClassDB.class_call_static("NariAnimation", "save_poster", ProjectSettings.globalize_path(moving), ProjectSettings.globalize_path(file), size)
	if not (saved and animated and keep_animation):
		DirAccess.remove_absolute(moving)
	return ProjectSettings.globalize_path(file) if saved else ""

static func _fit(bytes: PackedByteArray, size: int) -> Image:
	var image: = _decode(bytes)
	if image == null or image.is_empty():
		return null
	var longest: = maxi(image.get_width(), image.get_height())
	if longest > size:
		var scale: = float(size) / longest
		image.resize(maxi(roundi(image.get_width() * scale), 1), maxi(roundi(image.get_height() * scale), 1), Image.INTERPOLATE_LANCZOS)
	return image

static func _sort_title(title: String) -> String:
	var trimmed: = title.strip_edges().to_lower()
	for article in ["the ", "a ", "an "]:
		if trimmed.begins_with(article):
			return trimmed.substr(article.length()).strip_edges()
	return trimmed

static func _decode(bytes: PackedByteArray) -> Image:
	var image: = Image.new()
	var header: = bytes.slice(0, 4).get_string_from_ascii()
	var error: Error
	if header.ends_with("PNG"):
		error = image.load_png_from_buffer(bytes)
	elif header == "RIFF":
		error = image.load_webp_from_buffer(bytes)
	else:
		error = image.load_jpg_from_buffer(bytes)
	return image if error == OK else null

static func _field(source: Dictionary, key: String) -> Dictionary:
	var value: Variant = source.get(key)
	return value if value is Dictionary else {}
