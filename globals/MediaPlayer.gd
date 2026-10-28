extends Node

signal volume_changed(volume: float)
signal playback_changed(state: Dictionary)
signal library_changed
signal library_ready(success: bool, error: String)
signal library_loading_changed(loading: bool)
signal music_provider_changed
signal music_effect_changed(state: Dictionary)
signal playlists_changed
signal playlist_image_picked(path: String)
signal now_playing_requested
signal current_song_changed(song: Dictionary)
signal offline_changed
signal likes_changed(kind: String, id: String, liked: bool)
signal song_played(song: Dictionary)
signal history_changed
signal cast_state_changed(state: Dictionary)

enum Repeat{OFF, ALL, ONE}
enum Context{ALL, ALBUM, ARTIST, PLAYLIST, QUEUE}
enum MusicEffect{NONE, CONCERT, RADIO, ROBOT, HELIUM, SENIOR, EIGHT_BIT, INSTRUMENTAL, ACAPELLA, GRAMOPHONE}

const TAPE_SCRUB: = preload("res://systems/music/tape_scrub.gd")
const HINT_KINDS: = {"artist": 1, "album": 2, "track": 4}
const RADIO_SIZE: = 50
const RADIO_ARTIST_SHARE: = 15
const SEARCH_ORDER: = ["title", "artist", "album"]
const SEARCH_FIELDS: = {"title": "title", "artist": "artist", "album": "album", "genre": "genres", "date": "year"}
const COVER_ALBUM: = "album"
const COVER_SONG: = "song"
const COVER_PLAYLIST: = "playlist"
const COVER_ARTIST: = "artist"
const COLLAGE_SIZE: = 512
const LIKES_PATH: = "user://likes.json"
const RESUME_PATH: = "user://resume.json"
const RESUME_LIMIT: = 500
const RESUME_SAVE_MS: = 5000
const LIKED_PLAYLIST: = "liked"
const LIKE_KINDS: = ["track", "album", "artist"]
const PAGE_KINDS: = ["tracks", "albums", "artists", "playlist"]
const COLLECT_LIMIT: = 1000
const MAX_CACHED_TEXTURES: = 12
const MAX_CACHED_THUMBS: = 96
const MAX_CACHED_ANIMATED: = 2
const LOADING_DELAY: = 0.4
const LOADING_POLL: = 0.1
const PROVIDERS: = [
	preload("res://systems/music/providers/local_provider.gd"),
	preload("res://systems/music/providers/plex_provider.gd"),
	preload("res://systems/music/providers/subsonic_provider.gd"),
	preload("res://systems/music/providers/jellyfin_provider.gd"),
]

const _CONTEXT_NAMES: = {
	Context.ALL: "all",
	Context.ALBUM: "album",
	Context.ARTIST: "artist",
	Context.PLAYLIST: "playlist",
	Context.QUEUE: "queue",
}

const _EFFECT_NAMES: = {
	MusicEffect.NONE: "none",
	MusicEffect.CONCERT: "concert",
	MusicEffect.RADIO: "radio",
	MusicEffect.ROBOT: "robot",
	MusicEffect.HELIUM: "helium",
	MusicEffect.SENIOR: "senior",
	MusicEffect.EIGHT_BIT: "8_bit",
	MusicEffect.INSTRUMENTAL: "instrumental",
	MusicEffect.ACAPELLA: "acapella",
	MusicEffect.GRAMOPHONE: "gramophone",
}

var lyrics: = LyricsManager.new()
var play_session: = 0
var downloads: = Downloads.new()
var artist_info: = ArtistInfo.new()
var providers: Array[MusicProvider] = []
var provider: MusicProvider

var _l: = Log.new("MediaPlayer", Color("f2b05e"))
var _native: Object = null
var cast_state: Dictionary = {}
var _tape := TAPE_SCRUB.new()
var _state: Dictionary = {"connected": false}
var _current_song: Dictionary = {}
var _current_base: Dictionary = {}
var _jobs: = 0
var _direct: Dictionary = {}
var _opening: PackedStringArray = []
var _change_direction: = 1
var _library_cache: Dictionary = {}
var _textures: Dictionary = {}
var _thumb_textures: Dictionary = {}
var _texture_requests: Dictionary = {}
var _cover_players: Dictionary = {}
var _spectrum_warned: = false
var library_loading: = false
var _likes: = {}
var _watching_library: = false
var resumed: = false
var _resume: = {}
var _resume_version: = -1
var _resume_written: = 0
var _resume_tried: = false
var _resume_check: = false

func _ready() -> void :
	add_child(lyrics)
	add_child(_tape)
	add_child(artist_info)
	get_tree().root.files_dropped.connect(open_files)
	_likes = JsonUtil.parse_dict(FileAccess.get_file_as_string(LIKES_PATH)) if FileAccess.file_exists(LIKES_PATH) else {}
	playlists_changed.connect( func():
		for key in _library_cache.keys():
			if str(key).begins_with("playlist"):
				_library_cache.erase(key))
	_discover_providers()
	use_provider(SettingsManager.library.provider)
	downloads.changed.connect(func(_song_id: String):
		if offline_mode() and not downloads.is_pending(provider.id, _song_id):
			_on_library_changed())
	SettingsManager.changed.connect(func(section: String, key: String, _value: Variant):
		if section == "general" and key == "offline_mode":
			offline_changed.emit()
			_on_library_changed()
		elif section == "performance" and key == "video_decoding":
			for cover_key: String in _cover_players.keys():
				_forget_cover(_textures, cover_key))
	_connect_native()
	if not _native:
		_l.warn("The native music service is unavailable, playback and the music library stay empty")
	_try_resume.call_deferred()

func set_volume(value: float, save: bool = true) -> void:
	if Plugins.is_output_connected():
		Plugins.output_volume(value)
		volume_changed.emit(value)
		return
	if _native and _native.has_method("setAppVolume"):
		_native.setAppVolume(value)
	if save and not is_casting():
		SettingsManager.playback.volume = value
	volume_changed.emit(value)

func follow_output() -> void:
	if Plugins.is_output_connected():
		if _native and _native.has_method("setAppVolume"):
			_native.setAppVolume(0.0)
	else:
		set_volume(SettingsManager.playback.volume, false)

func _connect_native() -> void :
	if _native or not Engine.has_singleton("MusicService"):
		return
	_native = Engine.get_singleton("MusicService")
	_native.connect("playback_changed", _on_playback_changed)
	_native.connect("music_effect_changed", _on_music_effect_changed)
	_native.connect("playlist_image_picked", playlist_image_picked.emit)
	_native.connect("cast_state_changed", _on_cast_state)
	cast_state = JsonUtil.parse_dict(_native.getCastStateJson())
	_native.connect("song_played", func(song_json: String):
		history_changed.emit()
		song_played.emit(JsonUtil.parse_dict(song_json)))
	if provider:
		_native.setHistoryProvider(provider.id)
	if _native.has_signal("now_playing_requested"):
		_native.connect("now_playing_requested", _on_now_playing_requested)
		_on_now_playing_requested.call_deferred()
	_native.setNormalizeVolume(SettingsManager.playback.normalize_volume)
	set_volume(SettingsManager.playback.volume, false)
	_native.setGapless(SettingsManager.playback.gapless)
	_native.setSoundFont(SettingsManager.playback.soundfont)
	_native.setModuleEnding(SettingsManager.playback.module_ending)
	_native.soundfont_picked.connect(func(path: String):
		if not path.is_empty():
			SettingsManager.playback.soundfont = path)
	_send_discord()
	music_provider_changed.connect(_send_discord)
	SettingsManager.changed.connect(func(section: String, key: String, value: Variant):
		if section == "playback" and key == "normalize_volume":
			_native.setNormalizeVolume(value)
		elif section == "playback" and key == "gapless":
			_native.setGapless(value)
		elif section == "playback" and key == "soundfont":
			_native.setSoundFont(value)
		elif section == "playback" and key == "module_ending":
			_native.setModuleEnding(value)
		elif section == "discord":
			_send_discord())
	_state =_with_effect_enum(JsonUtil.parse_dict(_native.getPlaybackStateJson()))
	_refresh_current_song()
	_l.log("Connected to the native music service")
	if is_library_loading() or not is_library_ready():
		_watch_library()

func _send_discord() -> void :
	var discord: = SettingsManager.discord
	_native.setDiscord(JSON.stringify({
		"enabled": discord.enabled,
		"status_name": discord.status_name,
		"show_paused": discord.show_paused,
		"song_button": discord.song_button,
		"nari_button": discord.nari_button,
		"fetch_artwork": discord.fetch_artwork,
		"provider": "Local Music" if provider == null or provider.id == "local" else provider.display_name,
	}))

func _discover_providers() -> void :
	for script: GDScript in PROVIDERS:
		register_provider(script.new())

func register_provider(entry: MusicProvider) -> void :
	entry.http = HTTPService.new()
	add_child(entry.http)
	providers.append(entry)
	entry.settings_changed.connect(_forget_discover.bind(entry.id))
	_l.log("Found music provider '%s'" % entry.id)
	if provider and entry.id == SettingsManager.library.provider and entry != provider:
		use_provider(entry.id)

func unregister_provider(entry: MusicProvider) -> void :
	providers.erase(entry)
	get_tree().create_timer(HTTPService.TIMEOUT).timeout.connect(entry.http.queue_free)
	if entry == provider:
		use_provider(SettingsManager.library.provider)

func get_provider(provider_id: String) -> MusicProvider:
	for entry in providers:
		if entry.id == provider_id:
			return entry
	return null

func use_provider(provider_id: String) -> void :
	var chosen: = get_provider(provider_id)
	if chosen == null:
		chosen = providers[0] if not providers.is_empty() else null
	if chosen == provider:
		return
	var switching: = provider != null
	if switching:
		provider.library_changed.disconnect(_on_library_changed)
		provider.library_ready.disconnect(_on_library_ready)
		provider.library_progress.disconnect(_watch_library)
		provider.settings_changed.disconnect(_on_provider_settings_changed)
		provider.reachability_changed.disconnect(offline_changed.emit)
	provider = chosen
	if provider == null:
		return
	if provider.id == provider_id:
		SettingsManager.library.provider = provider_id
	if _native:
		_native.setHistoryProvider(provider.id)
	provider.library_changed.connect(_on_library_changed)
	provider.library_ready.connect(_on_library_ready)
	provider.library_progress.connect(_watch_library)
	provider.settings_changed.connect(_on_provider_settings_changed)
	provider.reachability_changed.connect(offline_changed.emit)
	if switching:
		_on_library_changed()
		music_provider_changed.emit()
		offline_changed.emit()

func has_notification_permission() -> bool:
	return _native != null and _native.hasNotificationPermission()

func request_notification_permission() -> void :
	if _native:
		_native.requestNotificationPermission()

func play(song_id: String = "", context: Context = Context.ALL, context_id: String = "") -> void :
	if not _native:
		return
	if song_id.is_empty():
		_native.resume()
		return
	play_session += 1
	if context == Context.PLAYLIST and context_id == LIKED_PLAYLIST:
		play_tracks(get_liked("track"), song_id)
		return
	if provider and provider.streams and context != Context.QUEUE:
		_play_streamed(await _context_tracks(context, context_id), song_id, false)
		return
	_native.play(song_id, _CONTEXT_NAMES[context], context_id)

func play_shuffled(context: Context = Context.ALL, context_id: String = "") -> void :
	if not _native:
		return
	play_session += 1
	if context == Context.PLAYLIST and context_id == LIKED_PLAYLIST:
		play_tracks(get_liked("track"), "", true)
		return
	if provider and provider.streams:
		_play_streamed(await _context_tracks(context, context_id), "", true)
		return
	_native.playShuffled(_CONTEXT_NAMES[context], context_id)

func play_tracks(tracks: Array, song_id: String = "", shuffled: bool = false) -> void :
	if not _native or tracks.is_empty():
		return
	play_session += 1
	if provider and provider.streams:
		_play_streamed(tracks, song_id, shuffled)
		return
	_native.playSongs(PackedStringArray(tracks.map(func(track: Dictionary): return str(track.get("id", "")))), song_id, shuffled)

func start_radio(kind: String, data: Dictionary) -> void:
	var item_id: = str(data.get("id", ""))
	var found: Variant = await provider.get_radio(kind, item_id) if provider and not offline_mode() else null
	var tracks: Array = found if found is Array and not found.is_empty() else await _library_radio(kind, data)
	if kind == "track":
		tracks = [data] + tracks.filter(func(track: Dictionary): return str(track.get("id", "")) != item_id)
	play_tracks(tracks.slice(0, RADIO_SIZE))

func _library_radio(kind: String, data: Dictionary) -> Array:
	var artist_id: = str(data.get("artist_id", "")) if kind == "track" else str(data.get("id", ""))
	var by_artist: Array = []
	if not artist_id.is_empty():
		by_artist = await get_artist_tracks(artist_id)
	var genres: = {}
	var genre_sources: Array = [data] if kind == "track" else by_artist
	for source: Dictionary in genre_sources:
		for genre: Variant in source.get("genres", []):
			genres[str(genre)] = true
	var related: Array = []
	if not is_paged() and not genres.is_empty():
		for track: Dictionary in await get_tracks():
			if str(track.get("artist_id", "")) != artist_id and _shares_genre(track, genres):
				related.append(track)
	by_artist.shuffle()
	related.shuffle()
	var mixed: Array = by_artist.slice(0, RADIO_ARTIST_SHARE) + related
	mixed.shuffle()
	return mixed

func _shares_genre(track: Dictionary, genres: Dictionary) -> bool:
	for genre: Variant in track.get("genres", []):
		if genres.has(str(genre)):
			return true
	return false

func set_equalizer(bands: Array) -> void :
	if _native:
		_native.setEqualizer(PackedVector2Array(bands))

func _context_tracks(context: Context, context_id: String) -> Array:
	match context:
		Context.ALBUM:
			var album: Dictionary = await get_album(context_id)
			return album.get("tracks", [])
		Context.ARTIST:
			return await get_artist_tracks(context_id)
		Context.PLAYLIST:
			if context_id == LIKED_PLAYLIST:
				return get_liked("track")
			if is_paged():
				return await collect_pages("playlist", context_id)
			var playlist: Dictionary = await get_playlist(context_id)
			return playlist.get("tracks", [])
	if is_paged():
		return await collect_pages("tracks")
	return await get_tracks()

func _play_streamed(tracks: Array, song_id: String, shuffled: bool) -> void :
	await _register_streamed(tracks)
	_native.playSongs(PackedStringArray(tracks.map(func(track: Dictionary): return str(track.get("id", "")))), song_id, shuffled)

func _register_streamed(tracks: Array) -> void :
	var songs: Array = await provider.playable(tracks)
	for song: Dictionary in songs:
		var local: = downloads.path(provider.id, str(song.get("id", "")))
		if not local.is_empty():
			song["uri"] = offline_uri(str(song.get("uri", "")), local)
	_native.registerSongs(JSON.stringify(songs))

func _prepare_song(song_id: String) -> void :
	if provider and provider.streams:
		var song: Dictionary = await get_song(song_id)
		if not song.is_empty():
			await _register_streamed([song])

func toggle() -> void :
	if _native:
		_native.toggle()

func stop() -> void :
	if _native:
		play_session += 1
		_native.stop()

func next() -> void :
	if _native:
		_native.next()

func previous() -> void :
	if _native:
		_native.previous()

func seek(position_ms: int) -> void :
	if _native:
		_native.seekTo(position_ms)

func shuffle(enabled: Variant = null) -> void :
	if not _native:
		return
	_native.setShuffle( not is_shuffled() if enabled == null else bool(enabled))

func repeat(mode: Variant = null) -> void :
	if not _native:
		return
	var next_mode: int = (get_repeat() + 1) % 3 if mode == null else int(mode)
	_native.setRepeat(next_mode)

func is_playing() -> bool:
	return bool(_state.get("is_playing", false))

func is_shuffled() -> bool:
	return bool(_state.get("shuffle", false))

func get_repeat() -> Repeat:
	match int(_state.get("repeat", 0)):
		1: return Repeat.ALL
		2: return Repeat.ONE
	return Repeat.OFF

func get_playback_state() -> Dictionary:
	return _state

func get_change_direction() -> int:
	return _change_direction

func get_position() -> int:
	if _tape.scrubbing():
		return int(_tape.position_ms)
	return _native.getPositionMs() if _native else 0

func get_buffered() -> PackedVector2Array:
	return _native.getBuffered() if _native else PackedVector2Array()

func get_duration() -> int:
	return _native.getDurationMs() if _native else 0

func get_tracks() -> Array:
	if offline_mode():
		return downloads.tracks(provider.id)
	var tracks: Array = await _cached("tracks", func(): return await provider.get_tracks(), [])
	if tracks.is_empty() and can_download():
		return downloads.tracks(provider.id)
	return tracks

func can_download() -> bool:
	return provider != null and provider.streams

func offline_mode() -> bool:
	return can_download() and SettingsManager.general.offline_mode

func is_offline() -> bool:
	return offline_mode() or (can_download() and not provider.reachable)

func is_downloaded(song_id: String) -> bool:
	return can_download() and downloads.has(provider.id, song_id)

func is_downloading(song_id: String) -> bool:
	return can_download() and downloads.is_pending(provider.id, song_id)

func download(song: Dictionary) -> void :
	if can_download():
		await downloads.download(provider, song)

func remove_download(song_id: String) -> void :
	if can_download():
		downloads.remove(provider.id, song_id)

func get_albums() -> Array:
	if offline_mode():
		return _downloaded_albums()
	var albums: Array = await _cached("albums", func(): return await provider.get_albums(), [])
	return _downloaded_albums() if albums.is_empty() and can_download() else albums

func get_artists() -> Array:
	if offline_mode():
		return _downloaded_artists()
	var artists: Array = await _cached("artists", func(): return await _with_counts(await provider.get_artists()), [])
	return _downloaded_artists() if artists.is_empty() and can_download() else artists

func _downloaded_albums() -> Array:
	var albums: = {}
	for track: Dictionary in downloads.tracks(provider.id):
		var album_id: = str(track.get("album_id", ""))
		if not albums.has(album_id):
			albums[album_id] = {
				"id": album_id,
				"title": str(track.get("album", "Unknown album")),
				"artist": str(track.get("artist", "")),
				"artist_id": str(track.get("artist_id", "")),
				"year": int(track.get("year", 0)),
				"release_type": "album",
				"song_count": 0,
				"duration": 0,
				"tracks": [],
			}
		var album: Dictionary = albums[album_id]
		album["song_count"] += 1
		album["duration"] += int(track.get("duration", 0))
		album["tracks"].append(track)
	var found: = albums.values()
	for album: Dictionary in found:
		album["tracks"].sort_custom(func(first: Dictionary, second: Dictionary):
			return int(first.get("disc_number", 0)) * 1000 + int(first.get("track_number", 0)) < int(second.get("disc_number", 0)) * 1000 + int(second.get("track_number", 0)))
	found.sort_custom(func(first: Dictionary, second: Dictionary): return str(first["title"]).naturalnocasecmp_to(str(second["title"])) < 0)
	return found

func _downloaded_artists() -> Array:
	var artists: = {}
	for album: Dictionary in _downloaded_albums():
		var artist_id: = str(album.get("artist_id", ""))
		if not artists.has(artist_id):
			artists[artist_id] = {
				"id": artist_id,
				"name": str(album.get("artist", "Unknown artist")),
				"album_count": 0,
				"song_count": 0,
				"duration": 0,
				"cover_album_id": str(album.get("id", "")),
				"albums": [],
				"tracks": [],
			}
		var artist: Dictionary = artists[artist_id]
		artist["album_count"] += 1
		artist["song_count"] += int(album["song_count"])
		artist["duration"] += int(album["duration"])
		artist["albums"].append(album)
		artist["tracks"].append_array(album["tracks"])
	var found: = artists.values()
	found.sort_custom(func(first: Dictionary, second: Dictionary): return str(first["name"]).naturalnocasecmp_to(str(second["name"])) < 0)
	return found

func _downloaded_entry(entries: Array, entry_id: String) -> Dictionary:
	for entry: Dictionary in entries:
		if str(entry.get("id", "")) == entry_id:
			return entry
	return {}

func download_tracks(tracks: Array) -> void :
	for track: Dictionary in tracks:
		if not is_downloaded(str(track.get("id", ""))):
			download(track)

func remove_downloads(tracks: Array) -> void :
	for track: Dictionary in tracks:
		remove_download(str(track.get("id", "")))

func _with_counts(artists: Array) -> Array:
	if artists.all(func(artist: Dictionary): return int(artist.get("song_count", 0)) > 0):
		return artists
	var songs: = {}
	var albums: = {}
	var durations: = {}
	for track: Dictionary in await get_tracks():
		var artist_id: = str(track.get("artist_id", ""))
		songs[artist_id] = int(songs.get(artist_id, 0)) + 1
		durations[artist_id] = int(durations.get(artist_id, 0)) + int(track.get("duration", 0))
		if not albums.has(artist_id):
			albums[artist_id] = {}
		albums[artist_id][str(track.get("album_id", ""))] = true
	for artist: Dictionary in artists:
		var artist_id: = str(artist.get("id", ""))
		if int(artist.get("song_count", 0)) == 0:
			artist["song_count"] = int(songs.get(artist_id, 0))
			artist["duration"] = int(durations.get(artist_id, 0))
		if int(artist.get("album_count", 0)) == 0:
			artist["album_count"] = albums.get(artist_id, {}).size()
	return artists

func search(query: String, filters: Dictionary = {}) -> Dictionary:
	var found: Variant = await provider.search(query, filters) if provider else null
	if found is Dictionary:
		return found
	var text: = _search_key(query)
	var wanted: = {}
	for key: String in filters:
		wanted[key] = _search_key(str(filters[key]))
	var in_playlist: = {}
	if wanted.has("playlist"):
		for playlist: Dictionary in await get_playlists():
			if _search_key(str(playlist.get("name", ""))).contains(wanted.playlist):
				var full: Dictionary = await get_playlist(str(playlist.get("id", "")))
				for track: Dictionary in full.get("tracks", []):
					in_playlist[str(track.get("id", ""))] = true
	var tracks: Array = await get_tracks()
	var index: Array = await _cached("search_index", func():
		return tracks.map(func(track: Dictionary):
			var keys: = {}
			for key: String in SEARCH_FIELDS:
				var value: Variant = track.get(SEARCH_FIELDS[key], "")
				keys[key] = _search_key(" ".join(PackedStringArray(value)) if value is Array else str(value))
			return keys), [])
	var ranked: Array = [[], [], []]
	for position in mini(tracks.size(), index.size()):
		var keys: Dictionary = index[position]
		if not _passes(keys, wanted, in_playlist.has(str(tracks[position].get("id", "")))):
			continue
		var rank: = 0
		if not text.is_empty():
			rank = -1
			for order in SEARCH_ORDER.size():
				if keys[SEARCH_ORDER[order]].contains(text):
					rank = order
					break
		if rank >= 0:
			ranked[rank].append(tracks[position])
	var albums: Array = []
	var artists: Array = []
	if filters.is_empty() or wanted.keys().all(func(key: String): return key in ["album", "artist"]):
		var album_name: String = wanted.get("album", text)
		var artist_name: String = wanted.get("artist", "" if wanted.has("album") else text)
		albums = (await get_albums()).filter(func(album: Dictionary):
			var title: = _search_key(str(album.get("title", "")))
			var artist: = _search_key(str(album.get("artist", "")))
			if filters.is_empty():
				return title.contains(text) or artist.contains(text)
			return title.contains(album_name) and artist.contains(wanted.get("artist", "")))
		if not wanted.has("album"):
			artists = (await get_artists()).filter(func(artist: Dictionary): return _search_key(str(artist.get("name", ""))).contains(artist_name))
	return {"tracks": ranked[0] + ranked[1] + ranked[2], "albums": albums, "artists": artists}

func get_hints(query: String) -> Array:
	if provider == null or query.strip_edges().is_empty():
		return []
	var given: Variant = await provider.get_hints(query) if not offline_mode() else null
	if given is Array:
		return given
	var found: = await search(query)
	var hints: Array = []
	for kind: String in HINT_KINDS:
		for item: Dictionary in found.get(kind + "s", []).slice(0, HINT_KINDS[kind]):
			hints.append({"kind": kind, "item": item})
	return hints

func _passes(keys: Dictionary, wanted: Dictionary, in_playlist: bool) -> bool:
	for key: String in wanted:
		var value: String = wanted[key]
		match key:
			"playlist":
				if not in_playlist:
					return false
			"date":
				var bounds: = value.split("-", false)
				var year: String = keys.date
				if bounds.size() == 2 and not (year.to_int() >= bounds[0].to_int() and year.to_int() <= bounds[1].to_int()):
					return false
				if bounds.size() != 2 and not year.begins_with(value):
					return false
			_:
				if not str(keys.get(key, "")).contains(value):
					return false
	return true

func get_genres() -> Array:
	var given: Variant = await provider.get_genres() if provider else null
	if given is Array:
		return given
	if is_paged():
		return []
	var counts: = {}
	for track: Dictionary in await get_tracks():
		for genre: Variant in track.get("genres", []):
			var name: = str(genre).strip_edges()
			if not name.is_empty():
				counts[name] = int(counts.get(name, 0)) + 1
	var genres: = counts.keys()
	genres.sort_custom(func(a: String, b: String): return counts[a] > counts[b])
	return genres

func _search_key(text: String) -> String:
	if text.is_empty():
		return text
	return TextServerManager.get_primary_interface().strip_diacritics(text).to_lower()

func get_album(album_id: String) -> Dictionary:
	if offline_mode():
		return _downloaded_entry(_downloaded_albums(), album_id)
	var album: Dictionary = await _cached("album:" + album_id, func(): return await provider.get_album(album_id), {})
	return _downloaded_entry(_downloaded_albums(), album_id) if album.is_empty() and can_download() else album

func get_artist(artist_id: String) -> Dictionary:
	if offline_mode():
		return _downloaded_entry(_downloaded_artists(), artist_id)
	var artist: Dictionary = await _cached("artist:" + artist_id, func(): return await provider.get_artist(artist_id), {})
	return _downloaded_entry(_downloaded_artists(), artist_id) if artist.is_empty() and can_download() else artist

func get_artist_tracks(artist_id: String) -> Array:
	var artist: Dictionary = await get_artist(artist_id)
	return artist.get("tracks", [])

func get_song(song_id: String = "") -> Dictionary:
	if _direct.has(song_id):
		return _direct[song_id]
	if provider == null:
		return {}
	if offline_mode():
		return downloads.track(provider.id, song_id)
	var song: Dictionary = await provider.get_song(song_id)
	if song.is_empty() and can_download():
		return downloads.track(provider.id, song_id)
	return song

func open_target(target: String) -> void:
	if target.begins_with("nari://"):
		Plugins.open_link(target)
	else:
		open_files(PackedStringArray([target]))

func open_files(paths: PackedStringArray) -> void:
	if not _native:
		return
	var waiting: = not _opening.is_empty()
	for path in paths:
		if path.begins_with("content://") or _native.isAudioFile(path):
			_opening.append(path)
	if not waiting and not _opening.is_empty():
		_open_pending.call_deferred()

func _open_pending() -> void:
	if provider and provider.id == "local" and not is_library_ready():
		await library_ready
	var paths: = _opening
	_opening = PackedStringArray()
	var library: = {}
	if provider and provider.id == "local":
		for track: Dictionary in await get_tracks():
			library[str(track.get("uri", ""))] = track
	var ids: = PackedStringArray()
	var direct: = PackedStringArray()
	for path in paths:
		var song: Dictionary = library.get(path, {})
		if song.is_empty():
			var raw: String = _native.fileSongJson(path, "")
			song = JsonUtil.parse_dict(raw)
			_direct[str(song["id"])] = song
			direct.append(raw)
		ids.append(str(song.get("id", "")))
	if ids.is_empty():
		return
	if not direct.is_empty():
		_native.registerSongs("[%s]" % ",".join(direct))
	_native.playSongs(ids, ids[0], false)
	Main.open_now_playing()

func play_uri(song: Dictionary) -> void:
	var song_id: = str(song.get("id", ""))
	if not _native or song_id.is_empty() or str(song.get("uri", "")).is_empty():
		return
	song["duration"] = int(song.get("duration", 0))
	_direct[song_id] = song
	_native.registerSongs(JSON.stringify([song]))
	_native.playSongs(PackedStringArray([song_id]), song_id, false)

func pick_soundfont() -> void:
	if _native:
		_native.pickSoundFont()

func is_sealed(uri: String) -> bool:
	return _native != null and _native.isSealed(uri)

func offline_uri(uri: String, local: String) -> String:
	return "%s?offline=%s" % [uri, local.uri_encode()] if is_sealed(uri) else local

func save_stream(uri: String, path: String) -> Dictionary:
	if not _native:
		return {"ok": false, "error": "the player is not ready"}
	_jobs += 1
	var id: = _jobs
	_native.saveStream(id, uri, path)
	return await _job(id)

func analyze(target: Variant, options: Dictionary = {}) -> Dictionary:
	if not _native:
		return {"error": "the player is not ready"}
	var uri: = str(target) if target is String else await _uri_of(target if target is Dictionary else {})
	if uri.is_empty():
		return {"error": "the song has nothing to analyze"}
	_jobs += 1
	var id: = _jobs
	_native.analyze(id, uri, JSON.stringify(options))
	return await _job(id)

func _uri_of(song: Dictionary) -> String:
	var song_id: = str(song.get("id", ""))
	if provider:
		var local: = downloads.path(provider.id, song_id)
		if provider.streams:
			var playable: Array = await provider.playable([song])
			var uri: = str(playable[0].get("uri", "")) if not playable.is_empty() else ""
			return uri if local.is_empty() else offline_uri(uri, local)
		if not local.is_empty():
			return local
	if not song.has("uri") and not song_id.is_empty():
		song = await get_song(song_id)
	return str(song.get("uri", ""))

func native_job(start: Callable) -> Dictionary:
	if not _native:
		return {"ok": false, "error": "the player is not ready"}
	_jobs += 1
	var id: = _jobs
	start.call(id)
	return await _job(id)

func _job(id: int) -> Dictionary:
	while true:
		var done: Array = await _native.job_done
		if int(done[0]) == id:
			return JsonUtil.parse_dict(str(done[1]))
	return {}

func get_current_song() -> Dictionary:
	return _current_song

func get_raw_lyrics(song_id: String) -> Dictionary:
	if provider == null:
		return {}
	return await provider.get_raw_lyrics(song_id)

func get_queue() -> Array:
	if not _native:
		return []
	var songs: = JsonUtil.parse_array(_native.getQueueSongsJson())
	if is_paged():
		return songs
	var tracks: Dictionary = await _cached("tracks_by_id", func():
		var by_id: = {}
		for track in await get_tracks():
			by_id[str(track.get("id", ""))] = track
		return by_id, {})
	return songs.map(func(song: Variant) -> Variant: return tracks.get(str(song.get("id", "")), song) if song is Dictionary else song)

func get_playlists() -> Array:
	var liked: = _liked_playlist()
	var own: Array = [] if offline_mode() else await _cached("playlists", func(): return await provider.get_playlists(), [])
	return ([liked] if not liked.is_empty() else []) + own

func get_playlist(playlist_id: String) -> Dictionary:
	if playlist_id == LIKED_PLAYLIST:
		var liked: = _liked_playlist()
		liked["tracks"] = get_liked("track")
		return liked
	if offline_mode():
		return {}
	return await _cached("playlist:" + playlist_id, func(): return await provider.get_playlist(playlist_id), {})

func is_paged() -> bool:
	return provider != null and provider.paged and not offline_mode()

func get_page(kind: String, context_id: String, offset: int, limit: int) -> Dictionary:
	if is_paged():
		var page: Variant = await provider.get_page(kind, context_id, offset, limit)
		if page is Dictionary:
			var items: Array = page.get("items", [])
			return {"items": items, "more": bool(page.get("more", items.size() >= limit))}
		return {"items": [], "more": false}
	var all: Array = []
	match kind:
		"tracks": all = await get_tracks()
		"albums": all = await get_albums()
		"artists": all = await get_artists()
		"playlist": all = (await get_playlist(context_id)).get("tracks", [])
	return {"items": all.slice(offset, offset + limit), "more": offset + limit < all.size()}

func collect_pages(kind: String, context_id: String = "", cap: int = COLLECT_LIMIT) -> Array:
	var collected: = []
	while collected.size() < cap:
		var page: = await get_page(kind, context_id, collected.size(), mini(100, cap - collected.size()))
		collected.append_array(page["items"])
		if not page["more"] or page["items"].is_empty():
			break
	return collected

func get_history(limit: int = 0) -> Array:
	if not _native or provider == null:
		return []
	var history: = JsonUtil.parse_array(_native.getHistoryJson(provider.id))
	return history.slice(0, limit) if limit > 0 else history

func get_history_json() -> String:
	return _native.getHistoryJson(provider.id) if _native and provider else "[]"

func get_top(kind: String, limit: int = 20) -> Array:
	var groups: = {}
	for entry: Dictionary in get_history():
		var key: = str(entry.get({"track": "id", "album": "album_id", "artist": "artist_id"}.get(kind, "id"), ""))
		if key.is_empty():
			continue
		if not groups.has(key):
			groups[key] = {"id": key, "plays": 0, "last_played": 0, "title": entry.get("album" if kind == "album" else "title", ""), "name": entry.get("artist", ""), "artist": entry.get("artist", ""), "track": entry}
		groups[key]["plays"] += int(entry.get("plays", 0))
		groups[key]["last_played"] = maxi(groups[key]["last_played"], int(entry.get("last_played", 0)))
	var top: = groups.values()
	top.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["plays"] > b["plays"] or a["plays"] == b["plays"] and a["last_played"] > b["last_played"])
	return top.slice(0, limit)

func clear_history() -> void :
	if _native and provider:
		_native.clearHistory(provider.id)
		history_changed.emit()

func is_liked(kind: String, id: String) -> bool:
	return _liked_items(kind).has(id)

func get_liked(kind: String) -> Array:
	var items: = _liked_items(kind).values()
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.get("liked_at", 0)) > float(b.get("liked_at", 0)))
	return items

func toggle_like(kind: String, item: Dictionary) -> void :
	set_liked(kind, item, not is_liked(kind, str(item.get("id", ""))))

func set_liked(kind: String, item: Dictionary, liked: bool) -> void :
	var id: = str(item.get("id", ""))
	if id.is_empty() or not kind in LIKE_KINDS or is_liked(kind, id) == liked:
		return
	var items: = _liked_items(kind)
	if liked:
		var entry: = item.duplicate()
		entry["liked_at"] = Time.get_unix_time_from_system()
		items[id] = entry
	else:
		items.erase(id)
	_save_likes()
	likes_changed.emit(kind, id, liked)
	if kind == "track":
		playlists_changed.emit()
	if provider and provider.supports_likes:
		await provider.set_liked(kind, id, liked)

func sync_likes() -> void :
	if provider == null or not provider.supports_likes or offline_mode():
		return
	for kind: String in LIKE_KINDS:
		var found: Variant = await provider.get_liked(kind)
		if not found is Array:
			continue
		var items: = _liked_items(kind)
		var fresh: = {}
		for entry: Variant in found:
			if entry is Dictionary and not str(entry.get("id", "")).is_empty():
				var known: Dictionary = items.get(str(entry["id"]), {})
				var merged: Dictionary = entry.duplicate()
				merged["liked_at"] = known.get("liked_at", entry.get("liked_at", Time.get_unix_time_from_system()))
				fresh[str(entry["id"])] = merged
		_likes[provider.id][kind] = fresh
	_save_likes()
	likes_changed.emit("", "", true)
	playlists_changed.emit()

func _liked_items(kind: String) -> Dictionary:
	var provider_id: = provider.id if provider else ""
	if not _likes.has(provider_id):
		_likes[provider_id] = {}
	if not _likes[provider_id].has(kind):
		_likes[provider_id][kind] = {}
	return _likes[provider_id][kind]

func _save_likes() -> void :
	FileUtil.write_json(LIKES_PATH, _likes)

func _liked_playlist() -> Dictionary:
	var tracks: = get_liked("track")
	if tracks.is_empty():
		return {}
	return {
		"id": LIKED_PLAYLIST,
		"name": "Liked songs",
		"song_count": tracks.size(),
		"duration": tracks.reduce(func(total: int, track: Dictionary) -> int: return total + int(track.get("duration", 0)), 0),
		"modified": int(float(tracks[0].get("liked_at", 0))),
		"cover_album_ids": [],
		"generated": true,
	}

func playlist_cover_id(playlist: Dictionary) -> String:
	return "%s@%s" % [playlist.get("id", ""), playlist.get("modified", 0)]

func create_playlist(playlist_name: String) -> String:
	if provider == null:
		return ""
	var playlist_id: String = await provider.create_playlist(playlist_name)
	playlists_changed.emit()
	return playlist_id

func delete_playlist(playlist_id: String) -> void :
	if provider:
		await provider.delete_playlist(playlist_id)
		playlists_changed.emit()

func rename_playlist(playlist_id: String, playlist_name: String) -> void :
	if provider:
		await provider.rename_playlist(playlist_id, playlist_name)
		playlists_changed.emit()

func add_to_playlist(playlist_id: String, song_ids: PackedStringArray) -> void :
	if playlist_id == LIKED_PLAYLIST:
		for song_id in song_ids:
			set_liked("track", await get_song(song_id), true)
		return
	if provider:
		await provider.add_to_playlist(playlist_id, song_ids)
		playlists_changed.emit()

func remove_from_playlist(playlist_id: String, song_id: String) -> void :
	if playlist_id == LIKED_PLAYLIST:
		set_liked("track", {"id": song_id}, false)
		return
	if provider:
		await provider.remove_from_playlist(playlist_id, song_id)
		playlists_changed.emit()

func pick_playlist_image() -> void :
	if _native:
		_native.pickPlaylistImage()

func set_playlist_image(playlist_id: String, path: String) -> void :
	if provider:
		await provider.set_playlist_image(playlist_id, path)
		playlists_changed.emit()

func add_to_queue(song_id: String) -> void :
	if _native:
		await _prepare_song(song_id)
		_native.addToQueue(song_id)

func queue_tracks(tracks: Array) -> void :
	if not _native or tracks.is_empty():
		return
	if provider and provider.streams:
		await _register_streamed(tracks)
	for track: Dictionary in tracks:
		_native.addToQueue(str(track.get("id", "")))

func play_next(song_id: String) -> void :
	if _native:
		await _prepare_song(song_id)
		_native.playNext(song_id)

func play_next_tracks(tracks: Array) -> void :
	for index in range(tracks.size() - 1, -1, -1):
		await play_next(str(tracks[index].get("id", "")))

func remove_from_queue(index: int) -> void :
	if _native:
		_native.removeFromQueue(index)

func move_in_queue(from: int, to: int) -> void :
	if _native:
		_native.moveInQueue(from, to)

func clear_upcoming() -> void :
	if _native:
		_native.clearQueue()

func skip_to_queue_index(index: int) -> void :
	if _native:
		_native.skipToQueueIndex(index)

func apply_music_effect(effect: MusicEffect) -> bool:
	if not _native or not _EFFECT_NAMES.has(effect):
		return false
	return _native.applyMusicEffect(_EFFECT_NAMES[effect])

func apply_custom_effect(id: String, spec: Dictionary) -> bool:
	if not _native:
		return false
	var applied: bool = _native.applyCustomEffect(id, JSON.stringify(spec))
	if not applied:
		_l.warn("Effect '%s' has an invalid chain" % id)
	return applied

func apply_music_distortion(speed: float, pitch: float) -> void :
	if _native:
		_native.applyMusicDistortion(speed, pitch)

func reset_music_effect() -> void :
	if _native:
		_native.resetMusicEffect()

func reset_music_distortion() -> void :
	if _native:
		_native.resetMusicDistortion()

func is_library_loading() -> bool:
	return provider != null and provider.is_loading()

func is_library_ready() -> bool:
	return provider != null and provider.is_ready()

func get_library_status() -> Dictionary:
	return provider.get_status() if provider else {}

func _watch_library() -> void :
	if _watching_library:
		return
	_watching_library = true
	await get_tree().create_timer(LOADING_DELAY).timeout
	if is_library_loading():
		library_loading = true
		library_loading_changed.emit(true)
		while is_library_loading():
			await get_tree().create_timer(LOADING_POLL).timeout
		library_loading = false
	_watching_library = false
	library_loading_changed.emit(false)

func is_library_pending() -> bool:
	return _watching_library or library_loading

func effect_id(effect: MusicEffect) -> String:
	return _EFFECT_NAMES.get(effect, "none")

func get_music_effect_state() -> Dictionary:
	return _with_effect_enum(JsonUtil.parse_dict(_native.getMusicEffectStateJson())) if _native else {
		"effect": MusicEffect.NONE,
		"speed": 1.0,
		"pitch": 1.0
	}

func get_spectrum() -> PackedByteArray:
	if not _native:
		return PackedByteArray()
	var data: Variant = _native.getAudioSpectrum()
	if data is PackedByteArray:
		return data
	if not _spectrum_warned:
		_spectrum_warned = true
		_l.warn("The native service returned %s instead of bytes, visualizers stay flat" % type_string(typeof(data)))
	return PackedByteArray()

func set_spectrum_latency(milliseconds: int) -> void:
	if _native:
		_native.setAudioSpectrumLatency(milliseconds)

func cover_of(song: Dictionary) -> Array:
	var album_id: = str(song.get("album_id", ""))
	return [COVER_SONG, str(song.get("id", ""))] if album_id.is_empty() or song.get("own_cover", false) else [COVER_ALBUM, album_id]

func has_cover_texture(kind: String, id: String, thumb: bool = false) -> bool:
	thumb = thumb and kind != COVER_PLAYLIST
	return (_thumb_textures if thumb else _textures).has(kind + ":" + id)

func get_cover_texture(kind: String, id: String, thumb: bool = false) -> Texture2D:
	thumb = thumb and kind != COVER_PLAYLIST
	var cache: Dictionary = _thumb_textures if thumb else _textures
	var key: = kind + ":" + id
	if cache.has(key):
		var cached: Texture2D = cache[key]
		cache.erase(key)
		cache[key] = cached
		return cached
	var request_key: = key + (":thumb" if thumb else "")
	var request: MusicProvider.Request = _texture_requests.get(request_key)
	if request == null:
		request = MusicProvider.Request.new()
		_texture_requests[request_key] = request
		_load_cover_texture(kind, id, thumb, request)
	if request.finished:
		return request.result
	return await request.done

func get_cover_image(kind: String, id: String, thumb: bool = false) -> Image:
	var path: = await _request_cover(kind, id, thumb)
	if path.is_empty():
		return null
	return await Worker.run(_load_image.bind(path))

func _load_cover_texture(kind: String, id: String, thumb: bool, request: MusicProvider.Request) -> void :
	var image: Image
	var texture: Texture2D
	if kind == COVER_PLAYLIST:
		image = await _playlist_image(id.get_slice("@", 0))
	elif kind == COVER_ARTIST:
		image = await _artist_image(id, thumb)
	else:
		var path: = await _request_cover(kind, id, thumb)
		if not thumb and not path.is_empty():
			texture = await _animated_cover(kind + ":" + id, path.get_basename() + ".anim")
		if texture == null and not path.is_empty():
			image = await Worker.run(_load_image.bind(path))
	if texture == null and image:
		texture = ImageTexture.create_from_image(image)
	var cache: Dictionary = _thumb_textures if thumb else _textures
	cache[kind + ":" + id] = texture
	if cache.size() > (MAX_CACHED_THUMBS if thumb else MAX_CACHED_TEXTURES):
		_forget_cover(cache, cache.keys()[0])
	var animated: = cache.keys().filter( func(key: String): return _cover_players.has(key)) if not thumb else []
	if animated.size() > MAX_CACHED_ANIMATED:
		_forget_cover(cache, animated[0])
	_texture_requests.erase(kind + ":" + id + (":thumb" if thumb else ""))
	request.finish(texture)

func _animated_cover(key: String, file: String) -> Texture2D:
	var player: = MotionPlayer.create(file)
	if player == null:
		return null
	add_child(player)
	var error: String = await player.settled
	if not error.is_empty():
		player.queue_free()
		return null
	_cover_players[key] = player
	return player.texture

func _forget_cover(cache: Dictionary, key: String) -> void :
	cache.erase(key)
	if is_same(cache, _textures) and _cover_players.has(key):
		_cover_players[key].release()
		_cover_players.erase(key)

func watch_cover(texture: Texture2D, viewer: CanvasItem) -> void :
	for player: MotionPlayer in _cover_players.values():
		if player.texture == texture:
			player.watch(viewer)

func _artist_image(artist_id: String, thumb: bool) -> Image:
	if provider and provider.streams:
		var own: = await get_cover_image(COVER_ALBUM, artist_id, thumb)
		if own:
			return own
	if thumb:
		for artist: Dictionary in await get_artists():
			if str(artist.get("id", "")) == artist_id:
				var photo: = await artist_info.image(str(artist.get("name", "")), true)
				return photo if photo else await get_cover_image(COVER_ALBUM, str(artist.get("cover_album_id", "")), true)
		return null
	var artist: Dictionary = await get_artist(artist_id)
	var online: = await artist_info.image(str(artist.get("name", "")), false)
	if online:
		return online
	return await _collage_image(artist.get("albums", []).map(func(album: Dictionary): return str(album.get("id", ""))))

func _load_image(path: String) -> Image:
	var image: = Image.load_from_file(path)
	return image if image and not image.is_empty() else null

func _playlist_image(playlist_id: String) -> Image:
	if playlist_id == LIKED_PLAYLIST:
		return GeneratedCover.image(GeneratedCover.LIKED)
	var playlist: Dictionary = {"cover_album_ids": [playlist_id]}
	for entry in await get_playlists():
		if str(entry.get("id", "")) == playlist_id:
			playlist = entry
			break
	var image_path: = str(playlist.get("image", ""))
	if not image_path.is_empty():
		return await Worker.run(_load_image.bind(image_path))
	return await _collage_image(playlist.get("cover_album_ids", []))

func _collage_image(album_ids: Array) -> Image:
	if album_ids.is_empty():
		return null
	if album_ids.size() < 4:
		return await get_cover_image(COVER_ALBUM, str(album_ids[0]))
	var paths: = PackedStringArray()
	for index in 4:
		paths.append(await _request_cover(COVER_ALBUM, str(album_ids[index]), true))
	return await Worker.run(_build_collage.bind(paths, GeneratedCover.image(COVER_ALBUM)))

func _build_collage(paths: PackedStringArray, fallback: Image) -> Image:
	var half: = int(COLLAGE_SIZE * 0.5)
	var collage: = Image.create_empty(COLLAGE_SIZE, COLLAGE_SIZE, false, Image.FORMAT_RGBA8)
	for index in paths.size():
		var tile: Image = _load_image(paths[index]) if not paths[index].is_empty() else null
		if tile == null:
			tile = fallback.duplicate()
		if tile.is_compressed():
			tile.decompress()
		tile.convert(Image.FORMAT_RGBA8)
		tile.resize(half, half, Image.INTERPOLATE_BILINEAR)
		collage.blit_rect(tile, Rect2i(0, 0, half, half), Vector2i(index % 2, int(index * 0.5)) * half)
	return collage

func format_song_count(count: int) -> String:
	return "%d %s" % [count, "song" if count == 1 else "songs"]

func format_duration(duration_ms: int) -> String:
	var total_seconds: = int(duration_ms / 1000.0)
	var hours: = int(total_seconds / 3600.0)
	if hours > 0:
		return "%d:%02d:%02d" % [hours, int(total_seconds / 60.0) % 60, total_seconds % 60]
	return "%d:%02d" % [int(total_seconds / 60.0), total_seconds % 60]

func _request_cover(kind: String, id: String, thumb: bool = false) -> String:
	if _direct.has(id):
		return str(_direct[id].get("cover", ""))
	if provider == null or id.is_empty():
		return ""
	return await provider.get_cover_path(kind, id, thumb)

func _cached(key: String, loader: Callable, fallback: Variant) -> Variant:
	if provider == null:
		return fallback
	if not _library_cache.has(key):
		_library_cache[key] = await loader.call()
	return _library_cache[key]

func _refresh_current_song() -> void :
	var song_id: = str(_state.get("current_id", ""))
	var song: Dictionary = {}
	if not song_id.is_empty():
		song = await get_song(song_id)
	if str(_state.get("current_id", "")) == song_id:
		_current_base = song
		_apply_stream_title()

func _apply_stream_title() -> void:
	var song := _current_base.duplicate()
	var title := str(_state.get("stream_title", ""))
	if bool(_state.get("live", false)) and not song.is_empty():
		song["live"] = true
		if not title.is_empty():
			var parts := title.split(" - ", true, 1)
			song["album"] = str(_current_base.get("title", ""))
			song["title"] = parts[1].strip_edges() if parts.size() == 2 else title
			song["artist"] = parts[0].strip_edges() if parts.size() == 2 else str(_current_base.get("title", ""))
	if song != _current_song:
		_current_song = song
		current_song_changed.emit(song)

func is_casting() -> bool:
	return str(cast_state.get("phase", "idle")) in ["connecting", "casting"]

func _on_cast_state(state_json: String) -> void :
	var was_casting := is_casting()
	cast_state = JsonUtil.parse_dict(state_json)
	var level := float(cast_state.get("volume", -1.0))
	if is_casting() and level >= 0.0:
		volume_changed.emit(level)
	elif was_casting and not is_casting():
		set_volume(SettingsManager.playback.volume, false)
	cast_state_changed.emit(cast_state)

func _on_playback_changed(state_json: String) -> void :
	var state: = _with_effect_enum(JsonUtil.parse_dict(state_json))
	var error: = str(state.get("error", ""))
	if error != str(_state.get("error", "")) and not error.is_empty():
		_l.error("Playback failed: ", error)
	if str(state.get("current_id", "")) != str(_state.get("current_id", "")):
		_change_direction = -1 if int(state.get("index", 0)) < int(_state.get("index", 0)) else 1
	var changed_song: = str(state.get("current_id", "")) != str(_current_song.get("id", ""))
	var changed_title: bool = state.get("stream_title", "") != _state.get("stream_title", "") or state.get("live", false) != _state.get("live", false)
	_state = state
	_check_resume(error)
	if changed_song:
		await _refresh_current_song()
	elif changed_title:
		_apply_stream_title()
	playback_changed.emit(_state)
	_track_resume()

func _on_library_changed() -> void :
	_library_cache.clear()
	await _refresh_current_song()
	for cache in [_textures, _thumb_textures]:
		for key in cache.keys():
			if cache[key] == null:
				cache.erase(key)
	library_changed.emit()

func _on_library_ready(success: bool, error: String) -> void :
	library_ready.emit(success, error)
	if success:
		sync_likes()
		_try_resume()

func _on_provider_settings_changed() -> void :
	music_provider_changed.emit()

func _forget_discover(provider_id: String) -> void :
	load("res://ui/screens/discover.gd").forget(provider_id)

func _on_now_playing_requested() -> void:
	if _native.takeNowPlayingRequest():
		now_playing_requested.emit()

func _on_music_effect_changed(state_json: String) -> void :
	var state: = _with_effect_enum(JsonUtil.parse_dict(state_json))
	music_effect_changed.emit(state)

func _with_effect_enum(state: Dictionary) -> Dictionary:
	var effect_name: = str(state.get("effect", "none"))
	var effect = _EFFECT_NAMES.find_key(effect_name)
	state["effect"] = effect if effect != null else MusicEffect.NONE
	state["custom"] = "" if effect != null else effect_name
	return state

func _notification(what: int) -> void :
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_EXIT_TREE]:
		write_resume()

func write_resume() -> void :
	if _resume.is_empty():
		return
	if FileUtil.write_json(RESUME_PATH, _resume):
		_resume_written = Time.get_ticks_msec()

func _track_resume() -> void :
	var current: = str(_state.get("current_id", ""))
	if not _resume_tried or current.is_empty() or provider == null or bool(_state.get("live", false)):
		return
	var version: = int(_state.get("queue_version", 0))
	if version != _resume_version or current != str(_resume.get("current", "")):
		_resume_version = version
		var tracks: Array = await get_queue()
		var index: = maxi(tracks.find_custom(func(track: Dictionary) -> bool: return str(track.get("id", "")) == current), 0)
		var start: = maxi(index - RESUME_LIMIT / 2, 0)
		_resume = {"provider": provider.id, "current": current, "tracks": tracks.slice(start, start + RESUME_LIMIT)}
		_resume_written = 0
	_resume["position"] = int(_state.get("position", 0))
	_resume["repeat"] = int(_state.get("repeat", 0))
	if Time.get_ticks_msec() - _resume_written > RESUME_SAVE_MS:
		write_resume()

func _try_resume() -> void :
	if _resume_tried or not _native or not is_library_ready():
		return
	_resume_tried = true
	if not str(_state.get("current_id", "")).is_empty() or not FileAccess.file_exists(RESUME_PATH):
		return
	var saved: = JsonUtil.parse_dict(FileAccess.get_file_as_string(RESUME_PATH))
	var tracks: Array = saved.get("tracks", []).filter(func(track: Variant) -> bool: return track is Dictionary)
	if str(saved.get("provider", "")) != provider.id or tracks.is_empty():
		DirAccess.remove_absolute(RESUME_PATH)
		return
	if provider.streams and not offline_mode():
		await _register_streamed(tracks)
	var ids: = PackedStringArray(tracks.map(func(track: Dictionary) -> String: return str(track.get("id", ""))))
	if not str(_state.get("current_id", "")).is_empty():
		return
	if not _native.restoreSongs(ids, str(saved.get("current", "")), int(saved.get("position", 0))):
		_l.warn("Quick resume skipped: the last song isn't available")
		DirAccess.remove_absolute(RESUME_PATH)
		return
	resumed = true
	_resume_check = true
	_native.setRepeat(int(saved.get("repeat", 0)))

func _check_resume(error: String) -> void :
	if not _resume_check:
		return
	if not error.is_empty():
		_resume_check = false
		_l.warn("Quick resume failed, starting fresh: ", error)
		DirAccess.remove_absolute(RESUME_PATH)
		_resume = {}
		_native.stop()
	elif bool(_state.get("is_playing", false)):
		_resume_check = false
