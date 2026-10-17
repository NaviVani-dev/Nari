class_name PlexMusicProvider extends MusicProvider

const CONFIG_PATH: = "user://providers/plex.cfg"
const COVER_DIR: = "user://providers/plex/covers"
const PLEX_TV: = "https://plex.tv/api/v2"
const AUTH_APP: = "https://app.plex.tv/auth#?clientID=%s&code=%s&context%%5Bdevice%%5D%%5Bproduct%%5D=Nari"
const PAGE_SIZE: = 500
const COVER_SIZE: = 720
const THUMB_SIZE: = 300
const COVER_QUALITY: = 0.9
const TRACK: = 10
const ALBUM: = 9
const ARTIST: = 8
const LYRICS_STREAM: = 4
const UNREACHABLE: = "Could not reach the server"
const TRANSCODE_PROFILE: = "add-transcode-target(type=musicProfile&context=streaming&protocol=http&container=mp3&audioCodec=mp3)"

var server_name: = ""
var _server: = ""
var _token: = ""
var _client_id: = ""
var _machine_id: = ""
var _sections: Array = []
var _cover_ids: Dictionary = {}
var _covers: Dictionary = {}
var _playlist_items: Dictionary = {}

func _init() -> void :
	super ("plex", "Plex", "Streams the music from your Plex Media Server", preload("res://assets/icons/plex.svg"), Color("e5a00d"))
	streams = true
	supports_quality = true
	var config: = Vault.load_config(CONFIG_PATH)
	_server = str(config.get_value("server", "url", ""))
	_token = str(config.get_value("server", "token", ""))
	_machine_id = str(config.get_value("server", "machine_id", ""))
	server_name = str(config.get_value("server", "name", ""))
	_client_id = str(config.get_value("client", "id", ""))
	if _client_id.is_empty():
		_client_id = Crypto.new().generate_random_bytes(16).hex_encode()
		_save()

func is_configured() -> bool:
	return not _token.is_empty() and not _server.is_empty()

func is_ready() -> bool:
	return is_configured()

func setup_entries() -> Array:
	return [{
		"title": "Server",
		"description": server_name if is_configured() else "Sign in with your Plex account",
		"icon": preload("res://assets/icons/plex.svg"),
		"value": func(): return "Connected" if is_configured() else "Sign in",
		"action": PlexLogin.open.bind(self),
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

func request_pin() -> Dictionary:
	var response: = await http.request(PLEX_TV + "/pins", _headers(""), HTTPClient.METHOD_POST)
	var pin: = response.body_as_dict() if response and response.succeeded() else {}
	if pin.has("code"):
		pin["id"] = str(int(pin.get("id", 0)))
		pin["auth_url"] = AUTH_APP % [_client_id.uri_encode(), str(pin["code"]).uri_encode()]
	return pin

func check_pin(pin_id: String) -> String:
	var response: = await http.request("%s/pins/%s" % [PLEX_TV, pin_id], _headers(""))
	var token: Variant = response.body_as_dict().get("authToken") if response and response.succeeded() else null
	return str(token) if token != null else ""

func find_servers(account_token: String) -> Array:
	var response: = await http.request(PLEX_TV + "/resources?includeHttps=1&includeRelay=1", _headers(account_token))
	if response == null or not response.succeeded():
		return []
	return response.body_as_array().filter(func(resource: Variant) -> bool:
		return resource is Dictionary and str(resource.get("provides", "")).split(",").has("server"))

func use_server(resource: Dictionary) -> String:
	var token: = str(resource.get("accessToken", ""))
	for address in _addresses(resource.get("connections", [])):
		var identity: = await _call(address, token, "/identity", {})
		if identity.has("error"):
			continue
		_server = address
		_token = token
		_machine_id = str(identity.get("machineIdentifier", resource.get("clientIdentifier", "")))
		server_name = str(resource.get("name", "Plex"))
		_sections.clear()
		_save()
		_l.log("Connected to %s at %s" % [server_name, _server])
		settings_changed.emit()
		library_changed.emit()
		return ""
	return "Could not reach %s from this device" % resource.get("name", "the server")

func sign_out() -> void :
	_server = ""
	_token = ""
	_machine_id = ""
	server_name = ""
	_sections.clear()
	_cover_ids.clear()
	_save()
	settings_changed.emit()
	library_changed.emit()

func get_tracks() -> Array:
	var tracks: = (await _section_items(TRACK)).map(_song)
	tracks.sort_custom(func(first: Dictionary, second: Dictionary): return first["sort_title"] < second["sort_title"])
	return tracks

func get_albums() -> Array:
	var albums: = (await _section_items(ALBUM)).map(_album)
	albums.sort_custom(func(first: Dictionary, second: Dictionary): return SubsonicMusicProvider._sort_title(first["title"]) < SubsonicMusicProvider._sort_title(second["title"]))
	return albums

func get_artists() -> Array:
	return (await _section_items(ARTIST)).map(_artist)

func get_album(album_id: String) -> Dictionary:
	var entry: = _first(await _api("/library/metadata/" + album_id), "Metadata")
	if entry.is_empty():
		return {}
	var album: = _album(entry)
	var tracks: Array = _list(await _api("/library/metadata/%s/children" % album_id), "Metadata").map(_song)
	album["tracks"] = tracks
	album["song_count"] = tracks.size()
	album["duration"] = tracks.reduce(func(total: int, track: Dictionary): return total + int(track["duration"]), 0)
	return album

func get_artist(artist_id: String) -> Dictionary:
	var entry: = _first(await _api("/library/metadata/" + artist_id), "Metadata")
	if entry.is_empty():
		return {}
	var artist: = _artist(entry)
	var albums: Array = _list(await _api("/library/metadata/%s/children" % artist_id), "Metadata").map(_album)
	var tracks: Array = _list(await _api("/library/metadata/%s/allLeaves" % artist_id), "Metadata").map(_song)
	artist["albums"] = albums
	artist["album_count"] = albums.size()
	artist["tracks"] = tracks
	artist["song_count"] = tracks.size()
	artist["duration"] = tracks.reduce(func(total: int, track: Dictionary): return total + int(track["duration"]), 0)
	artist["cover_album_id"] = str(albums[0]["id"]) if not albums.is_empty() else artist_id
	artist["bio"] = str(entry.get("summary", ""))
	artist["similar"] = entry.get("Similar", []).map(func(tag: Dictionary): return str(tag.get("tag", "")))
	return artist

func get_song(song_id: String) -> Dictionary:
	var entry: = _first(await _api("/library/metadata/" + song_id), "Metadata")
	return _song(entry) if not entry.is_empty() else {}

func get_raw_lyrics(song_id: String) -> Dictionary:
	var entry: = _first(await _api("/library/metadata/" + song_id, {"includeLyrics": 1}), "Metadata")
	var part: = _first(_first(entry, "Media"), "Part")
	for stream: Variant in part.get("Stream", []):
		if stream is Dictionary and int(stream.get("streamType", 0)) == LYRICS_STREAM and stream.has("key"):
			var response: = await http.request(_url(_server, _token, str(stream["key"]), {}), _headers(_token))
			if response and response.succeeded():
				var synced: = str(stream.get("codec", "")) == "lrc"
				return {"text": response.body_as_string(), "format": "lrc" if synced else "txt", "source": "plex", "song_id": song_id}
	return {}

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
			"cover_url": _cover_url(cover_id, COVER_SIZE),
			"replay_gain": track.get("replay_gain"),
		})

func media_uri(track: Dictionary, quality: String) -> String:
	if not transcodes(quality):
		return _url(_server, _token, str(track.get("part_key", "")), {})
	return _url(_server, _token, "/music/:/transcode/universal/start.mp3", {
		"path": "/library/metadata/" + str(track.get("id", "")),
		"mediaIndex": 0,
		"partIndex": 0,
		"protocol": "http",
		"directPlay": 0,
		"directStream": 0,
		"musicBitrate": BITRATES[quality],
		"session": Crypto.new().generate_random_bytes(8).hex_encode(),
		"X-Plex-Client-Identifier": _client_id,
		"X-Plex-Product": str(ProjectSettings.get_setting("application/config/name", "Nari")),
		"X-Plex-Platform": "Generic",
		"X-Plex-Client-Profile-Extra": TRANSCODE_PROFILE,
	})

func get_cover_path(_kind: String, cover_id: String, thumb: bool) -> String:
	if cover_id.is_empty():
		return ""
	var file: = _cover_file(cover_id, thumb)
	if FileAccess.file_exists(file):
		return ProjectSettings.globalize_path(file)
	if not reachable:
		return ""
	if not is_configured():
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
	return _list(await _api("/playlists", {"playlistType": "audio"}), "Metadata").map(_playlist)

func get_playlist(playlist_id: String) -> Dictionary:
	var entry: = _first(await _api("/playlists/" + playlist_id), "Metadata")
	if entry.is_empty():
		return {}
	var playlist: = _playlist(entry)
	var items: Array = _list(await _api("/playlists/%s/items" % playlist_id), "Metadata")
	var item_ids: Dictionary = {}
	for item: Dictionary in items:
		var song_id: = str(item.get("ratingKey", ""))
		item_ids[song_id] = item_ids.get(song_id, []) + [str(int(item.get("playlistItemID", 0)))]
	_playlist_items[playlist_id] = item_ids
	playlist["tracks"] = items.map(_song)
	return playlist

func create_playlist(playlist_name: String) -> String:
	var answer: = await _api("/playlists", {"type": "audio", "smart": 0, "title": playlist_name, "uri": _library_uri("")}, HTTPClient.METHOD_POST)
	return str(_first(answer, "Metadata").get("ratingKey", ""))

func delete_playlist(playlist_id: String) -> void :
	await _api("/playlists/" + playlist_id, {}, HTTPClient.METHOD_DELETE)

func rename_playlist(playlist_id: String, playlist_name: String) -> void :
	await _api("/playlists/" + playlist_id, {"title": playlist_name}, HTTPClient.METHOD_PUT)

func add_to_playlist(playlist_id: String, song_ids: PackedStringArray) -> void :
	await _api("/playlists/%s/items" % playlist_id, {"uri": _library_uri("/library/metadata/" + ",".join(song_ids))}, HTTPClient.METHOD_PUT)

func remove_from_playlist(playlist_id: String, song_id: String) -> void :
	await get_playlist(playlist_id)
	for item_id: String in _playlist_items.get(playlist_id, {}).get(song_id, []):
		await _api("/playlists/%s/items/%s" % [playlist_id, item_id], {}, HTTPClient.METHOD_DELETE)

func _save() -> void :
	var config: = ConfigFile.new()
	config.set_value("client", "id", _client_id)
	if is_configured():
		config.set_value("server", "url", _server)
		config.set_value("server", "token", _token)
		config.set_value("server", "machine_id", _machine_id)
		config.set_value("server", "name", server_name)
	Vault.save_config(config, CONFIG_PATH)

func _headers(token: String) -> PackedStringArray:
	var headers: = PackedStringArray([
		"Accept: application/json",
		"X-Plex-Client-Identifier: " + _client_id,
		"X-Plex-Product: " + str(ProjectSettings.get_setting("application/config/name", "Nari")),
		"X-Plex-Version: " + str(ProjectSettings.get_setting("application/config/version", "1.0")),
		"X-Plex-Platform: " + OS.get_name(),
		"X-Plex-Device-Name: " + str(ProjectSettings.get_setting("application/config/name", "Nari")),
	])
	if not token.is_empty():
		headers.append("X-Plex-Token: " + token)
	return headers

func _addresses(connections: Array) -> PackedStringArray:
	var ranked: Array = [[], [], [], []]
	for connection: Variant in connections:
		if not connection is Dictionary:
			continue
		var uri: = str(connection.get("uri", "")).trim_suffix("/")
		if bool(connection.get("relay", false)):
			ranked[3].append(uri)
		elif bool(connection.get("local", false)):
			ranked[0].append(uri)
			ranked[1].append("http://%s:%s" % [connection.get("address", ""), int(connection.get("port", 32400))])
		else:
			ranked[2].append(uri)
	var addresses: = PackedStringArray()
	for group: Array in ranked:
		for uri: String in group:
			if not uri.is_empty() and not addresses.has(uri):
				addresses.append(uri)
	return addresses

func _api(path: String, params: Dictionary = {}, method: HTTPClient.Method = HTTPClient.METHOD_GET) -> Dictionary:
	if not is_configured():
		return {}
	var answer: = await _call(_server, _token, path, params, method)
	set_reachable(answer.get("error") != UNREACHABLE)
	if answer.has("error"):
		_l.warn("%s failed: %s" % [path, answer["error"]])
		return {}
	return answer

func _call(server: String, token: String, path: String, params: Dictionary, method: HTTPClient.Method = HTTPClient.METHOD_GET) -> Dictionary:
	if http == null:
		return {"error": "The network service is not ready"}
	var response: = await http.request(_url(server, "", path, params), _headers(token), method)
	if response == null or response.result != HTTPRequest.RESULT_SUCCESS:
		return {"error": UNREACHABLE}
	if response.code == 401:
		return {"error": "Plex did not accept the sign in, try signing in again"}
	if not response.succeeded():
		return {"error": "The server answered with code %d" % response.code}
	if response.body.is_empty():
		return {}
	return SubsonicMusicProvider._field(response.body_as_dict(), "MediaContainer")

func _url(server: String, token: String, path: String, params: Dictionary) -> String:
	var values: = params.duplicate()
	if not token.is_empty():
		values["X-Plex-Token"] = token
	var query: = HTTPService.dictionary_to_query(values)
	if query.is_empty():
		return server + path
	var joiner: = "&" if path.contains("?") else "?"
	return server + path + joiner + query

func _library_uri(path: String) -> String:
	return "server://%s/com.plexapp.plugins.library%s" % [_machine_id, path]

func _section_items(kind: int) -> Array:
	if _sections.is_empty():
		_sections = _list(await _api("/library/sections"), "Directory").filter(func(section: Dictionary): return str(section.get("type", "")) == "artist")
	var found: Array = []
	for section: Dictionary in _sections:
		var start: = 0
		while true:
			var page: = _list(await _api("/library/sections/%s/all" % section.get("key", ""), {"type": kind, "X-Plex-Container-Start": start, "X-Plex-Container-Size": PAGE_SIZE}), "Metadata")
			found.append_array(page)
			start += page.size()
			if page.size() < PAGE_SIZE:
				break
	return found

func _song(entry: Dictionary) -> Dictionary:
	var song_id: = str(entry.get("ratingKey", ""))
	var album_id: = str(entry.get("parentRatingKey", ""))
	_remember_cover(album_id if not album_id.is_empty() else song_id, entry.get("parentThumb", entry.get("thumb")))
	var media: = _first(entry, "Media")
	var part: = _first(media, "Part")
	var file_name: = str(part.get("file", "")).get_file()
	if file_name.is_empty():
		file_name = "%s.%s" % [song_id, part.get("container", media.get("container", ""))]
	var title: = str(entry.get("title", "Unknown title"))
	var artist: = str(entry.get("originalTitle", entry.get("grandparentTitle", "")))
	return {
		"id": song_id,
		"title": title,
		"sort_title": SubsonicMusicProvider._sort_title(title),
		"artist": artist,
		"artists": [artist],
		"artist_id": str(entry.get("grandparentRatingKey", "")),
		"album": str(entry.get("parentTitle", "")),
		"album_id": album_id,
		"track_number": int(entry.get("index", 0)),
		"disc_number": int(entry.get("parentIndex", 0)),
		"year": int(entry.get("parentYear", entry.get("year", 0))),
		"duration": int(entry.get("duration", 0)),
		"genres": entry.get("Genre", []).map(func(genre: Dictionary): return str(genre.get("tag", ""))),
		"file_name": file_name,
		"part_key": str(part.get("key", "")),
		"mime_type": "",
		"bitrate": int(media.get("bitrate", 0)),
		"replay_gain": null,
	}

func _album(entry: Dictionary) -> Dictionary:
	var album_id: = str(entry.get("ratingKey", ""))
	_remember_cover(album_id, entry.get("thumb"))
	return {
		"id": album_id,
		"title": str(entry.get("title", "Unknown album")),
		"artist": str(entry.get("parentTitle", "")),
		"artist_id": str(entry.get("parentRatingKey", "")),
		"year": int(entry.get("year", 0)),
		"release_type": "album",
		"song_count": int(entry.get("leafCount", 0)),
		"duration": int(entry.get("duration", 0)),
	}

func _artist(entry: Dictionary) -> Dictionary:
	var artist_id: = str(entry.get("ratingKey", ""))
	_remember_cover(artist_id, entry.get("thumb"))
	return {
		"id": artist_id,
		"name": str(entry.get("title", "Unknown artist")),
		"album_count": int(entry.get("childCount", 0)),
		"song_count": 0,
		"duration": 0,
		"cover_album_id": artist_id,
	}

func _playlist(entry: Dictionary) -> Dictionary:
	var playlist_id: = str(entry.get("ratingKey", ""))
	_remember_cover(playlist_id, entry.get("composite", entry.get("thumb")))
	return {
		"id": playlist_id,
		"name": str(entry.get("title", "")),
		"song_count": int(entry.get("leafCount", 0)),
		"duration": int(entry.get("duration", 0)),
		"modified": int(entry.get("updatedAt", 0)),
		"cover_album_ids": [playlist_id],
		"image": "",
	}

func _remember_cover(cover_id: String, thumb: Variant) -> void :
	if not cover_id.is_empty() and thumb != null:
		_cover_ids[cover_id] = str(thumb)

func _cover_file(cover_id: String, thumb: bool) -> String:
	return "%s/%s_%d.jpg" % [COVER_DIR, cover_id.validate_filename(), THUMB_SIZE if thumb else COVER_SIZE]

func _cover_url(cover_id: String, size: int) -> String:
	var thumb: String = _cover_ids.get(cover_id, "/library/metadata/%s/thumb" % cover_id)
	return _url(_server, _token, "/photo/:/transcode", {"width": size, "height": size, "minSize": 1, "upscale": 1, "url": thumb})

func _original_cover_url(cover_id: String) -> String:
	var source: String = _cover_ids.get(cover_id, "/library/metadata/%s/thumb" % cover_id)
	return source if source.begins_with("http") else _url(_server, _token, source, {})

func _download_cover(cover_id: String, thumb: bool, file: String, request: Request) -> void :
	var response: = await http.request(_cover_url(cover_id, THUMB_SIZE) if thumb else _original_cover_url(cover_id), _headers(_token))
	var path: = ""
	if response and response.succeeded():
		path = await SubsonicMusicProvider.store_cover(response.body, file, THUMB_SIZE if thumb else COVER_SIZE, not thumb)
	_covers.erase(file)
	request.finish(path)

static func _list(source: Dictionary, key: String) -> Array:
	var value: Variant = source.get(key)
	return value.filter(func(entry: Variant): return entry is Dictionary) if value is Array else []

static func _first(source: Dictionary, key: String) -> Dictionary:
	var found: = _list(source, key)
	return found[0] if not found.is_empty() else {}
