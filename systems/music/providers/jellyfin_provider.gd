class_name JellyfinMusicProvider extends MusicProvider

const RELATED_SIZE: = 12
const RADIO_SIZE: = 50
const CONFIG_PATH: = "user://providers/jellyfin.cfg"
const COVER_DIR: = "user://providers/jellyfin/covers"
const SERVER_LOGIN: = preload("res://ui/shared/ServerLogin.tscn")
const PAGE_SIZE: = 500
const COVER_SIZE: = 720
const THUMB_SIZE: = 300
const TICKS_PER_MS: = 10000
const UNREACHABLE: = "Could not reach the server"
const SONG_FIELDS: = "Path,Genres,MediaSources"
const KINDS: = {"track": "Audio", "album": "MusicAlbum", "artist": "MusicArtist"}

var _server: = ""
var _user: = ""
var _user_id: = ""
var _token: = ""
var _device_id: = ""
var _covers: Dictionary = {}

func _init() -> void :
	super ("jellyfin", "Jellyfin", "Streams the music from your Jellyfin server", preload("res://assets/icons/jellyfin.svg"), Color("aa5cc3"))
	streams = true
	supports_quality = true
	supports_likes = true
	var config: = Vault.load_config(CONFIG_PATH)
	_server = str(config.get_value("server", "url", ""))
	_user = str(config.get_value("server", "user", ""))
	_user_id = str(config.get_value("server", "user_id", ""))
	_token = str(config.get_value("server", "token", ""))
	_device_id = str(config.get_value("client", "id", ""))
	if _device_id.is_empty():
		_device_id = Crypto.new().generate_random_bytes(16).hex_encode()
		_save()

func is_configured() -> bool:
	return not _token.is_empty() and not _server.is_empty()

func is_ready() -> bool:
	return is_configured()

func setup_entries() -> Array:
	return [{
		"title": "Server",
		"description": _server if is_configured() else "Sign in to your Jellyfin server",
		"icon": preload("res://assets/icons/jellyfin.svg"),
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
	var body: = JSON.stringify({"Username": user, "Pw": password})
	var answer: Dictionary = {}
	for address in [server] if server.contains("://") else ["https://" + server, "http://" + server]:
		answer = await _call(address, "", "/Users/AuthenticateByName", {}, HTTPClient.METHOD_POST, body)
		server = address
		if answer.get("error") != UNREACHABLE:
			break
	if answer.has("error"):
		return str(answer["error"])
	_server = server
	_user = user
	_user_id = str(SubsonicMusicProvider._field(answer, "User").get("Id", ""))
	_token = str(answer.get("AccessToken", ""))
	_save()
	_l.log("Signed in to %s as %s" % [_server, _user])
	settings_changed.emit()
	library_changed.emit()
	return ""

func sign_out() -> void :
	await _api("/Sessions/Logout", {}, HTTPClient.METHOD_POST)
	_server = ""
	_user = ""
	_user_id = ""
	_token = ""
	_save()
	settings_changed.emit()
	library_changed.emit()

func get_tracks() -> Array:
	return (await _pages({"IncludeItemTypes": "Audio", "SortBy": "SortName", "Fields": SONG_FIELDS})).map(_song)

func get_albums() -> Array:
	return (await _pages({"IncludeItemTypes": "MusicAlbum", "SortBy": "SortName", "Fields": "ChildCount"})).map(_album)

func get_artists() -> Array:
	return _items(await _api("/Artists/AlbumArtists", {"userId": _user_id, "SortBy": "SortName", "Fields": "ChildCount"})).map(_artist)

func get_album(album_id: String) -> Dictionary:
	var entry: = await _api("/Items/" + album_id, {"userId": _user_id})
	if entry.is_empty():
		return {}
	var album: = _album(entry)
	album["tracks"] = _items(await _api("/Items", {"userId": _user_id, "ParentId": album_id, "IncludeItemTypes": "Audio", "SortBy": "ParentIndexNumber,IndexNumber,SortName", "Fields": SONG_FIELDS})).map(_song)
	return album

func get_artist(artist_id: String) -> Dictionary:
	var entry: = await _api("/Items/" + artist_id, {"userId": _user_id, "Fields": "Overview"})
	if entry.is_empty():
		return {}
	var artist: = _artist(entry)
	var albums: Array = _items(await _api("/Items", {"userId": _user_id, "AlbumArtistIds": artist_id, "IncludeItemTypes": "MusicAlbum", "Recursive": true, "SortBy": "ProductionYear,SortName"})).map(_album)
	var tracks: Array = _items(await _api("/Items", {"userId": _user_id, "ArtistIds": artist_id, "IncludeItemTypes": "Audio", "Recursive": true, "SortBy": "Album,ParentIndexNumber,IndexNumber", "Fields": SONG_FIELDS})).map(_song)
	artist["albums"] = albums
	artist["album_count"] = albums.size()
	artist["tracks"] = tracks
	artist["song_count"] = tracks.size()
	artist["duration"] = tracks.reduce(func(total: int, track: Dictionary): return total + int(track["duration"]), 0)
	artist["cover_album_id"] = artist_id if entry.get("ImageTags", {}).has("Primary") or albums.is_empty() else str(albums[0]["id"])
	artist["bio"] = ArtistInfo._plain(str(entry.get("Overview", "")))
	artist["related"] = _items(await _api("/Items/%s/Similar" % artist_id, {"userId": _user_id, "limit": RELATED_SIZE})).map(_artist)
	return artist

func get_song(song_id: String) -> Dictionary:
	var entry: = await _api("/Items/" + song_id, {"userId": _user_id, "Fields": SONG_FIELDS})
	return _song(entry) if not entry.is_empty() else {}

func get_radio(_kind: String, item_id: String) -> Variant:
	var answer: = await _api("/Items/%s/InstantMix" % item_id, {"userId": _user_id, "limit": RADIO_SIZE, "Fields": SONG_FIELDS})
	return _items(answer).map(_song) if answer.has("Items") else null

func get_raw_lyrics(song_id: String) -> Dictionary:
	var found: Array = _items(await _api("/Audio/%s/Lyrics" % song_id), "Lyrics")
	if found.is_empty():
		return {}
	var synced: = found.all(func(line: Dictionary): return line.has("Start"))
	var lines: = PackedStringArray()
	for line: Dictionary in found:
		var text: = str(line.get("Text", ""))
		var start: = int(line.get("Start", 0)) / TICKS_PER_MS
		lines.append("[%02d:%02d.%02d]%s" % [int(start / 60000.0), int(start / 1000.0) % 60, int((start % 1000) / 10.0), text] if synced else text)
	return {"text": "\n".join(lines), "format": "lrc" if synced else "txt", "source": "jellyfin", "song_id": song_id}

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
	var song_id: = str(track.get("id", ""))
	if not transcodes(quality):
		return _url("/Audio/%s/stream" % song_id, {"static": true, "api_key": _token})
	return _url("/Audio/%s/stream.mp3" % song_id, {"audioCodec": "mp3", "audioBitRate": BITRATES[quality] * 1000, "api_key": _token})

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
	return (await _pages({"IncludeItemTypes": "Playlist", "MediaTypes": "Audio", "SortBy": "SortName", "Fields": "DateLastMediaAdded"})).map(_playlist)

func get_playlist(playlist_id: String) -> Dictionary:
	var entry: = await _api("/Items/" + playlist_id, {"userId": _user_id})
	if entry.is_empty():
		return {}
	var playlist: = _playlist(entry)
	playlist["tracks"] = (await _playlist_entries(playlist_id)).map(_song)
	return playlist

func create_playlist(playlist_name: String) -> String:
	var answer: = await _api("/Playlists", {}, HTTPClient.METHOD_POST, JSON.stringify({"Name": playlist_name, "UserId": _user_id, "MediaType": "Audio"}))
	return str(answer.get("Id", ""))

func delete_playlist(playlist_id: String) -> void :
	await _api("/Items/" + playlist_id, {}, HTTPClient.METHOD_DELETE)

func rename_playlist(playlist_id: String, playlist_name: String) -> void :
	await _api("/Playlists/" + playlist_id, {}, HTTPClient.METHOD_POST, JSON.stringify({"Name": playlist_name}))

func add_to_playlist(playlist_id: String, song_ids: PackedStringArray) -> void :
	await _api("/Playlists/%s/Items" % playlist_id, {"ids": ",".join(song_ids), "userId": _user_id}, HTTPClient.METHOD_POST)

func remove_from_playlist(playlist_id: String, song_id: String) -> void :
	var entries: Array = (await _playlist_entries(playlist_id)).filter(func(entry: Dictionary): return str(entry.get("Id", "")) == song_id)
	if not entries.is_empty():
		await _api("/Playlists/%s/Items" % playlist_id, {"entryIds": ",".join(entries.map(func(entry: Dictionary): return str(entry.get("PlaylistItemId", ""))))}, HTTPClient.METHOD_DELETE)

func get_liked(kind: String) -> Variant:
	if not KINDS.has(kind):
		return null
	var answer: = await _api("/Items", {"userId": _user_id, "IncludeItemTypes": KINDS[kind], "Recursive": true, "Filters": "IsFavorite", "SortBy": "SortName", "Fields": SONG_FIELDS})
	if answer.is_empty() and not reachable:
		return null
	match kind:
		"track": return _items(answer).map(_song)
		"album": return _items(answer).map(_album)
	return _items(answer).map(_artist)

func set_liked(_kind: String, id: String, liked: bool) -> void :
	await _api("/UserFavoriteItems/" + id, {"userId": _user_id}, HTTPClient.METHOD_POST if liked else HTTPClient.METHOD_DELETE)

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
	config.set_value("client", "id", _device_id)
	if is_configured():
		config.set_value("server", "url", _server)
		config.set_value("server", "user", _user)
		config.set_value("server", "user_id", _user_id)
		config.set_value("server", "token", _token)
	Vault.save_config(config, CONFIG_PATH)

func _headers(token: String) -> PackedStringArray:
	var app: = str(ProjectSettings.get_setting("application/config/name", "Nari"))
	var authorization: = 'MediaBrowser Client="%s", Device="%s", DeviceId="%s", Version="%s"' % [app, OS.get_name(), _device_id, ProjectSettings.get_setting("application/config/version", "1.0")]
	if not token.is_empty():
		authorization += ', Token="%s"' % token
	return PackedStringArray(["Accept: application/json", "Content-Type: application/json", "Authorization: " + authorization])

func _api(path: String, params: Dictionary = {}, method: HTTPClient.Method = HTTPClient.METHOD_GET, body: String = "") -> Dictionary:
	if not is_configured():
		return {}
	var answer: = await _call(_server, _token, path, params, method, body)
	set_reachable(answer.get("error") != UNREACHABLE)
	if answer.has("error"):
		_l.warn("%s failed: %s" % [path, answer["error"]])
		return {}
	return answer

func _call(server: String, token: String, path: String, params: Dictionary, method: HTTPClient.Method = HTTPClient.METHOD_GET, body: String = "") -> Dictionary:
	if http == null:
		return {"error": "The network service is not ready"}
	var query: = HTTPService.dictionary_to_query(params)
	var response: = await http.request(server + path + ("?" + query if not query.is_empty() else ""), _headers(token), method, body)
	if response == null or response.result != HTTPRequest.RESULT_SUCCESS:
		return {"error": UNREACHABLE}
	if response.code == 401:
		return {"error": "Jellyfin did not accept the user or password"}
	if not response.succeeded():
		return {"error": "The server answered with code %d, is it a Jellyfin server?" % response.code}
	if response.body.is_empty():
		return {}
	return response.body_as_dict()

func _url(path: String, params: Dictionary) -> String:
	return "%s%s?%s" % [_server, path, HTTPService.dictionary_to_query(params)]

func _pages(params: Dictionary) -> Array:
	var found: Array = []
	while true:
		var page: = _items(await _api("/Items", params.merged({"userId": _user_id, "Recursive": true, "StartIndex": found.size(), "Limit": PAGE_SIZE})))
		found.append_array(page)
		if page.size() < PAGE_SIZE:
			break
	return found

func _playlist_entries(playlist_id: String) -> Array:
	return _items(await _api("/Playlists/%s/Items" % playlist_id, {"userId": _user_id, "Fields": SONG_FIELDS}))

func _song(entry: Dictionary) -> Dictionary:
	var song_id: = str(entry.get("Id", ""))
	var source: = _first(entry, "MediaSources")
	var file_name: = str(entry.get("Path", "")).get_file()
	if file_name.is_empty():
		file_name = "%s.%s" % [song_id, entry.get("Container", "")]
	var title: = str(entry.get("Name", "Unknown title"))
	var artists: Array = entry.get("Artists", [])
	var artist: = str(entry.get("AlbumArtist", "")) if artists.is_empty() else ", ".join(artists)
	var artist_items: = _items(entry, "ArtistItems") + _items(entry, "AlbumArtists")
	return {
		"id": song_id,
		"title": title,
		"sort_title": SubsonicMusicProvider._sort_title(title),
		"artist": artist,
		"artists": artists if not artists.is_empty() else [artist],
		"artist_id": str(artist_items[0].get("Id", "")) if not artist_items.is_empty() else "",
		"album": str(entry.get("Album", "")),
		"album_id": str(entry.get("AlbumId", "")),
		"track_number": int(entry.get("IndexNumber", 0)),
		"disc_number": int(entry.get("ParentIndexNumber", 0)),
		"year": int(entry.get("ProductionYear", 0)),
		"duration": int(entry.get("RunTimeTicks", 0)) / TICKS_PER_MS,
		"genres": entry.get("Genres", []),
		"file_name": file_name,
		"mime_type": "",
		"bitrate": int(source.get("Bitrate", 0)) / 1000,
		"replay_gain": entry.get("NormalizationGain"),
	}

func _album(entry: Dictionary) -> Dictionary:
	var artists: = _items(entry, "AlbumArtists")
	return {
		"id": str(entry.get("Id", "")),
		"title": str(entry.get("Name", "Unknown album")),
		"artist": str(entry.get("AlbumArtist", "")),
		"artist_id": str(artists[0].get("Id", "")) if not artists.is_empty() else "",
		"year": int(entry.get("ProductionYear", 0)),
		"release_type": "album",
		"song_count": int(entry.get("ChildCount", entry.get("SongCount", 0))),
		"duration": int(entry.get("RunTimeTicks", 0)) / TICKS_PER_MS,
	}

func _artist(entry: Dictionary) -> Dictionary:
	var artist_id: = str(entry.get("Id", ""))
	return {
		"id": artist_id,
		"name": str(entry.get("Name", "Unknown artist")),
		"album_count": int(entry.get("AlbumCount", entry.get("ChildCount", 0))),
		"song_count": 0,
		"duration": 0,
		"cover_album_id": artist_id,
	}

func _playlist(entry: Dictionary) -> Dictionary:
	var playlist_id: = str(entry.get("Id", ""))
	return {
		"id": playlist_id,
		"name": str(entry.get("Name", "")),
		"song_count": int(entry.get("ChildCount", 0)),
		"duration": int(entry.get("RunTimeTicks", 0)) / TICKS_PER_MS,
		"modified": str(entry.get("DateLastMediaAdded", "")).hash(),
		"cover_album_ids": [playlist_id],
		"image": "",
	}

func _cover_file(cover_id: String, thumb: bool) -> String:
	return "%s/%s_%d.jpg" % [COVER_DIR, cover_id.validate_filename(), THUMB_SIZE if thumb else COVER_SIZE]

func _cover_url(cover_id: String, size: int) -> String:
	return _url("/Items/%s/Images/Primary" % cover_id, {"maxWidth": size, "maxHeight": size, "quality": 90})

func _download_cover(cover_id: String, thumb: bool, file: String, request: Request) -> void :
	var response: = await http.request(_cover_url(cover_id, THUMB_SIZE) if thumb else _url("/Items/%s/Images/Primary" % cover_id, {}), _headers(_token))
	var path: = ""
	if response and response.succeeded():
		path = await SubsonicMusicProvider.store_cover(response.body, file, THUMB_SIZE if thumb else COVER_SIZE, not thumb)
	_covers.erase(file)
	request.finish(path)

static func _items(source: Dictionary, key: String = "Items") -> Array:
	var value: Variant = source.get(key)
	return value.filter(func(entry: Variant): return entry is Dictionary) if value is Array else []

static func _first(source: Dictionary, key: String) -> Dictionary:
	var found: = _items(source, key)
	return found[0] if not found.is_empty() else {}
