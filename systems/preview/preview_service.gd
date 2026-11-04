extends Node

signal playback_changed(state: String)
signal cover_ready(kind: String, id: String, thumb: bool, path: String)
signal library_load_progress(status: String)
signal library_ready(success: bool, error: String)
signal music_folder_selected(kind: String, success: bool, uri: String)
signal music_effect_changed(state: String)
signal library_changed
signal soundboard_changed
signal soundboard_captured(success: bool)
signal playlist_image_picked(path: String)
signal plugin_picked(path: String)
signal theme_picked(path: String)
signal soundfont_picked(path: String)
signal text_picked(text: String)
signal scrobble_auth_url(service: String, url: String)
signal scrobble_account_changed(service: String, error: String)
signal tray_command(command: String)
signal now_playing_requested
signal link_opened(url: String)
signal song_played(song_json: String)
signal job_done(id: int, result_json: String)
signal cast_devices_changed(devices_json: String)
signal cast_state_changed(state_json: String)

const LIBRARY := "res://systems/preview/library.json"
const COVERS := "res://systems/preview/covers/%s.webp"
const COVER_DIR := "user://preview_covers"
const MUSIC_FOLDER := "/Music"
const BANDS := 32
const WAVE := 128

var _songs: Dictionary = {}
var _tracks: Array[Dictionary] = []
var _albums: Array[Dictionary] = []
var _artists: Array[Dictionary] = []
var _playlists: Array[Dictionary] = []
var _history: Array[Dictionary] = []
var _lyrics: Dictionary = {}
var _queue: PackedStringArray = []
var _index := 0
var _queue_version := 0
var _playing := false
var _shuffled := false
var _repeat := 0
var _position := 0
var _started := 0
var _effect := "none"
var _speed := 1.0
var _pitch := 1.0

func _init() -> void:
	var data := JsonUtil.parse_dict(FileAccess.get_file_as_string(LIBRARY))
	DirAccess.make_dir_recursive_absolute(COVER_DIR)
	for album: Dictionary in data.get("albums", []):
		_add_album(album)
	_artists.sort_custom(func(a: Dictionary, b: Dictionary): return str(a["name"]).naturalnocasecmp_to(b["name"]) < 0)
	for playlist: Dictionary in data.get("playlists", []):
		_playlists.append({"id": playlist["id"], "name": playlist["name"], "tracks": PackedStringArray(playlist["tracks"]), "image": ""})
	var now := int(Time.get_unix_time_from_system())
	for at in range(data.get("history", []).size()):
		var song: Dictionary = _songs[data["history"][at]]
		_history.append(_kept(song).merged({"plays": 3 + at, "last_played": now - at * 3600}))
	_lyrics = data.get("lyrics", {})
	_queue = PackedStringArray(_album(str(data.get("queue", ""))).get("tracks", []).map(func(song: Dictionary): return song["id"]))
	_index = maxi(_queue.find(str(data.get("playing", ""))), 0)
	_queue_version = 1
	_position = int(data.get("position", 0))
	_started = Time.get_ticks_msec()
	_playing = true

func _ready() -> void:
	var timer := Timer.new()
	timer.wait_time = 0.25
	timer.timeout.connect(_tick)
	add_child(timer)
	timer.start()

func _add_album(album: Dictionary) -> void:
	var album_id := str(album["id"])
	var artist := str(album["artist"])
	var artist_id := _slug(artist)
	_save_cover(album_id)
	var songs: Array[Dictionary] = []
	for number in album["tracks"].size():
		var entry: Array = album["tracks"][number]
		var artists: Array = entry[2] if entry.size() > 2 else [artist]
		var song := {
			"id": "%s-%d" % [album_id, number + 1], "title": entry[0], "sort_title": entry[0],
			"artist": ", ".join(artists), "artists": artists, "artist_id": artist_id, "artist_ids": artists.map(_slug),
			"album": album["title"], "album_id": album_id, "album_artist": artist, "genres": album.get("genres", []),
			"track_number": number + 1, "disc_number": 1, "year": album["year"], "duration": int(entry[1]) * 1000,
			"date_added": 1700000000 + _songs.size() * 600, "date_modified": 1700000000,
			"uri": "%s/%s/%s.flac" % [MUSIC_FOLDER, artist, entry[0]], "path": "%s/%s/%s/%02d %s.flac" % [MUSIC_FOLDER, artist, album["title"], number + 1, entry[0]],
			"file_name": "%02d %s.flac" % [number + 1, entry[0]], "file_size": int(entry[1]) * 110000, "mime_type": "audio/flac",
			"bitrate": 900, "sample_rate": 44100, "isrc": "", "musicbrainz_id": "", "release_type": album.get("release_type", "album"),
			"has_lyrics": false, "own_cover": false,
		}
		_songs[song["id"]] = song
		_tracks.append(song)
		songs.append(song)
	_albums.append({
		"id": album_id, "title": album["title"], "artist": artist, "artist_id": artist_id, "year": album["year"],
		"release_type": album.get("release_type", "album"), "tracks": songs,
	})
	var found := _artists.filter(func(entry: Dictionary): return entry["id"] == artist_id)
	if found.is_empty():
		_artists.append({"id": artist_id, "name": artist, "albums": [_albums[-1]]})
	else:
		found[0]["albums"].append(_albums[-1])

func _save_cover(album_id: String) -> void:
	var texture: Texture2D = load(COVERS % album_id)
	if texture:
		texture.get_image().save_webp(_cover_file(album_id))

func _cover_file(album_id: String) -> String:
	return COVER_DIR.path_join(album_id + ".webp")

static func _slug(name: String) -> String:
	return name.to_lower().replace(" ", "-")

func _kept(song: Dictionary) -> Dictionary:
	var kept := {}
	for key in ["id", "title", "artist", "artists", "album", "album_id", "artist_id", "duration"]:
		kept[key] = song[key]
	return kept

func _album(album_id: String) -> Dictionary:
	for album in _albums:
		if album["id"] == album_id:
			return album
	return {}

func _album_json(album: Dictionary, with_songs: bool) -> Dictionary:
	var songs: Array = album["tracks"]
	var value := album.duplicate()
	value.erase("tracks")
	value["song_count"] = songs.size()
	value["duration"] = songs.reduce(func(total: int, song: Dictionary): return total + int(song["duration"]), 0)
	value["date_added"] = songs.reduce(func(latest: int, song: Dictionary): return maxi(latest, int(song["date_added"])), 0)
	if with_songs:
		value["tracks"] = songs
	return value

func _artist_json(artist: Dictionary, with_content: bool) -> Dictionary:
	var songs := _tracks.filter(func(song: Dictionary): return song["artist_ids"].has(artist["id"]))
	var value := {
		"id": artist["id"], "name": artist["name"], "album_count": artist["albums"].size(), "song_count": songs.size(),
		"duration": songs.reduce(func(total: int, song: Dictionary): return total + int(song["duration"]), 0),
		"cover_album_id": artist["albums"][0]["id"],
	}
	if with_content:
		value["albums"] = artist["albums"].map(_album_json.bind(false))
		value["tracks"] = songs
	return value

func _playlist_json(playlist: Dictionary, with_songs: bool) -> Dictionary:
	var songs: Array = Array(playlist["tracks"]).filter(func(song_id: String): return _songs.has(song_id)).map(func(song_id: String): return _songs[song_id])
	var value := {"id": playlist["id"], "name": playlist["name"], "title": playlist["name"], "song_count": songs.size(), "image": playlist["image"],
		"duration": songs.reduce(func(total: int, song: Dictionary): return total + int(song["duration"]), 0)}
	if with_songs:
		value["tracks"] = songs
	return value

func _playlist(playlist_id: String) -> Dictionary:
	for playlist in _playlists:
		if playlist["id"] == playlist_id:
			return playlist
	return {}

func isMusicLibraryReady() -> bool:
	return true

func isMusicLibraryLoading() -> bool:
	return false

func getMusicLibraryStatusJson() -> String:
	return JSON.stringify({"ready": true, "loading": false, "stage": "", "loaded": _tracks.size(), "discovered": _tracks.size(), "progress": 1.0, "error": ""})

func getMusicFoldersJson() -> String:
	return JSON.stringify([{"name": "Music", "uri": MUSIC_FOLDER}])

func getIgnoredMusicFoldersJson() -> String:
	return "[]"

func requestAddMusicFolder() -> void:
	pass

func requestAddIgnoredMusicFolder() -> void:
	pass

func removeMusicFolder(_uri: String) -> bool:
	return false

func removeIgnoredMusicFolder(_uri: String) -> bool:
	return false

func refreshLibrary() -> void:
	pass

func rescanMusicLibrary(_clear_cache: bool) -> void:
	pass

func getTracksJson() -> String:
	return JSON.stringify(_tracks)

func getSongJson(song_id: String) -> String:
	return JSON.stringify(_songs.get(song_id if not song_id.is_empty() else _current_id(), {}))

func getRawLyricsJson(song_id: String) -> String:
	var text := str(_lyrics.get(song_id if not song_id.is_empty() else _current_id(), ""))
	return JSON.stringify({"text": text, "format": "lrc" if not text.is_empty() else "", "source": "file_lrc" if not text.is_empty() else "", "song_id": song_id})

func getAlbumsJson() -> String:
	return JSON.stringify(_albums.map(_album_json.bind(false)))

func getAlbumJson(album_id: String) -> String:
	var album := _album(album_id)
	return JSON.stringify(_album_json(album, true) if not album.is_empty() else {})

func getArtistsJson() -> String:
	return JSON.stringify(_artists.map(_artist_json.bind(false)))

func getArtistJson(artist_id: String) -> String:
	var found := _artists.filter(func(artist: Dictionary): return artist["id"] == artist_id)
	return JSON.stringify(_artist_json(found[0], true) if not found.is_empty() else {})

func getPlaylistsJson() -> String:
	return JSON.stringify(_playlists.map(_playlist_json.bind(false)))

func getPlaylistJson(playlist_id: String) -> String:
	var playlist := _playlist(playlist_id)
	return JSON.stringify(_playlist_json(playlist, true) if not playlist.is_empty() else {})

func createPlaylist(playlist_name: String) -> String:
	var playlist_id := "playlist-%d" % Time.get_ticks_usec()
	_playlists.append({"id": playlist_id, "name": playlist_name, "tracks": PackedStringArray(), "image": ""})
	library_changed.emit()
	return playlist_id

func deletePlaylist(playlist_id: String) -> void:
	_playlists.erase(_playlist(playlist_id))
	library_changed.emit()

func renamePlaylist(playlist_id: String, playlist_name: String) -> void:
	_playlist(playlist_id)["name"] = playlist_name
	library_changed.emit()

func addToPlaylist(playlist_id: String, song_ids: String) -> void:
	_playlist(playlist_id)["tracks"].append_array(song_ids.split(",", false))
	library_changed.emit()

func removeFromPlaylist(playlist_id: String, song_id: String) -> void:
	var tracks: PackedStringArray = _playlist(playlist_id)["tracks"]
	tracks.remove_at(tracks.find(song_id))
	_playlist(playlist_id)["tracks"] = tracks
	library_changed.emit()

func setPlaylistImage(_playlist_id: String, _path: String) -> void:
	pass

func pickPlaylistImage() -> void:
	pass

func getCachedCover(kind: String, cover_id: String, _thumb: bool) -> String:
	var album_id := cover_id if kind == "album" else str(_songs.get(cover_id, {}).get("album_id", ""))
	return _cover_file(album_id) if FileAccess.file_exists(_cover_file(album_id)) else ""

func requestCover(kind: String, cover_id: String, thumb: bool) -> void:
	cover_ready.emit.call_deferred(kind, cover_id, thumb, getCachedCover(kind, cover_id, thumb))

func getHistoryJson(_provider: String) -> String:
	return JSON.stringify(_history)

func clearHistory(_provider: String) -> void:
	_history.clear()

func setHistoryProvider(_provider: String) -> void:
	pass

func _current_id() -> String:
	return _queue[_index] if _index < _queue.size() else ""

func _now() -> int:
	return _position + (int((Time.get_ticks_msec() - _started) * _speed) if _playing else 0)

func _duration() -> int:
	return int(_songs.get(_current_id(), {}).get("duration", 0))

func _next_index() -> int:
	if _repeat == 2:
		return _index
	if _index + 1 < _queue.size():
		return _index + 1
	return 0 if _repeat == 1 and not _queue.is_empty() else -1

func _previous_index() -> int:
	return _index - 1 if _index > 0 else (_queue.size() - 1 if _repeat == 1 and not _queue.is_empty() else -1)

func _state() -> Dictionary:
	return {
		"connected": true, "casting": false, "error": "", "is_playing": _playing,
		"state": 1 if _queue.is_empty() else 3, "current_id": _current_id(), "index": _index,
		"queue_size": _queue.size(), "queue_version": _queue_version, "position": _now(), "duration": _duration(), "buffered": _duration(),
		"shuffle": _shuffled, "repeat": _repeat, "has_next": _next_index() != -1, "has_previous": _previous_index() != -1,
		"effect": _effect, "speed": _speed, "pitch": _pitch, "live": false, "stream_title": "",
	}

func _changed() -> void:
	playback_changed.emit(JSON.stringify(_state()))

func _tick() -> void:
	if _playing and _now() >= _duration():
		var next := _next_index()
		if next == -1:
			_position = 0
			_playing = false
			_changed()
		else:
			_go(next, true)

func _hold() -> void:
	_position = _now()
	_started = Time.get_ticks_msec()

func _go(index: int, playing: bool) -> void:
	_index = clampi(index, 0, maxi(_queue.size() - 1, 0))
	_position = 0
	_started = Time.get_ticks_msec()
	_playing = playing and not _queue.is_empty()
	_changed()
	if _playing:
		var song: Dictionary = _songs[_current_id()]
		var entry := _kept(song).merged({"plays": 1, "last_played": int(Time.get_unix_time_from_system())})
		_history = _history.filter(func(old: Dictionary): return old["id"] != song["id"])
		_history.push_front(entry)
		song_played.emit(JSON.stringify(entry))

func _start(ids: PackedStringArray, song_id: String, shuffled: bool) -> void:
	var known := Array(ids).filter(func(song_id: String): return _songs.has(song_id))
	if shuffled:
		known.shuffle()
	_queue = PackedStringArray(known)
	_queue_version += 1
	_shuffled = shuffled
	_go(maxi(_queue.find(song_id), 0) if not song_id.is_empty() else 0, true)

func _context(context_type: String, context_id: String) -> PackedStringArray:
	var songs: Array = _tracks
	match context_type:
		"album":
			songs = _album(context_id).get("tracks", [])
		"artist":
			songs = _tracks.filter(func(song: Dictionary): return song["artist_ids"].has(context_id))
		"playlist":
			return _playlist(context_id).get("tracks", PackedStringArray())
	return PackedStringArray(songs.map(func(song: Dictionary): return song["id"]))

func play(song_id: String, context_type: String, context_id: String) -> void:
	if context_type == "queue":
		_go(maxi(_queue.find(song_id), 0), true)
		return
	_start(_context(context_type, context_id), song_id, false)

func playShuffled(context_type: String, context_id: String) -> void:
	_start(_context(context_type, context_id), "", true)

func playSongs(ids: PackedStringArray, song_id: String, shuffled: bool) -> void:
	_start(ids, song_id, shuffled)

func registerSongs(songs_json: String) -> void:
	for song: Dictionary in JsonUtil.parse_array(songs_json):
		if not _songs.has(str(song.get("id", ""))):
			_songs[str(song["id"])] = song

func restoreSongs(_ids: PackedStringArray, _song_id: String, _position_ms: int) -> bool:
	return false

func resume() -> void:
	if not _playing and not _queue.is_empty():
		_started = Time.get_ticks_msec()
		_playing = true
		_changed()

func pause() -> void:
	if _playing:
		_hold()
		_playing = false
		_changed()

func toggle() -> void:
	if _playing:
		pause()
	else:
		resume()

func stop() -> void:
	_position = 0
	_playing = false
	_changed()

func next() -> void:
	var index := _next_index()
	_go(index if index != -1 else 0, _playing or index != -1)

func previous() -> void:
	if _now() > 3000 or _previous_index() == -1:
		seekTo(0)
		return
	_go(_previous_index(), true)

func seekTo(position_ms: int) -> void:
	_position = clampi(position_ms, 0, _duration())
	_started = Time.get_ticks_msec()
	_changed()

func setShuffle(enabled: bool) -> void:
	_shuffled = enabled
	_changed()

func setRepeat(mode: int) -> void:
	_repeat = mode
	_changed()

func skipToQueueIndex(index: int) -> void:
	_go(index, true)

func addToQueue(song_id: String) -> void:
	_queue.append(song_id)
	_queue_version += 1
	_changed()

func playNext(song_id: String) -> void:
	_queue.insert(_index + 1, song_id)
	_queue_version += 1
	_changed()

func removeFromQueue(index: int) -> void:
	if index == _index or index < 0 or index >= _queue.size():
		return
	_queue.remove_at(index)
	if index < _index:
		_index -= 1
	_queue_version += 1
	_changed()

func moveInQueue(from: int, to: int) -> void:
	var song_id := _queue[from]
	var current := _current_id()
	_queue.remove_at(from)
	_queue.insert(to, song_id)
	_index = _queue.find(current)
	_queue_version += 1
	_changed()

func clearQueue() -> void:
	var current := _current_id()
	_queue = PackedStringArray([current] if not current.is_empty() else [])
	_index = 0
	_queue_version += 1
	_changed()

func getQueueSongsJson() -> String:
	return JSON.stringify(Array(_queue).map(func(song_id: String): return _kept(_songs[song_id]).merged({"own_cover": false})))

func getQueueIdsJson() -> String:
	return JSON.stringify(_queue)

func getPlaybackStateJson() -> String:
	return JSON.stringify(_state())

func getPositionMs() -> int:
	return mini(_now(), _duration())

func getBuffered() -> PackedVector2Array:
	return PackedVector2Array([Vector2(0, _duration())])

func getDurationMs() -> int:
	return _duration()

func takeNowPlayingRequest() -> bool:
	return false

func getAudioSpectrum() -> PackedByteArray:
	var frame := PackedByteArray()
	frame.resize(BANDS + WAVE + 1)
	var time := _now() / 1000.0
	var beat := pow(maxf(sin(time * TAU * 2.0), 0.0), 4.0) if _playing else 0.0
	for band in BANDS:
		var level := (0.5 + 0.5 * sin(time * (2.0 + band * 0.37) + band)) * (1.0 - band / float(BANDS) * 0.6)
		frame[band] = int(clampf(level * (0.4 + 0.6 * beat), 0.0, 1.0) * 255.0) if _playing else 0
	for sample in WAVE:
		frame[BANDS + sample] = 128 + int(sin(sample / float(WAVE) * TAU * 3.0 + time * 8.0) * 60.0 * (0.3 + beat)) if _playing else 128
	frame[BANDS + WAVE] = int((0.35 + 0.5 * beat) * 255.0) if _playing else 0
	return frame

func setAudioSpectrumLatency(_milliseconds: int) -> void:
	pass

func applyMusicEffect(effect_id: String) -> bool:
	_effect = effect_id
	_effect_changed()
	return true

func applyCustomEffect(effect_id: String, _spec_json: String) -> bool:
	return applyMusicEffect(effect_id)

func applyMusicDistortion(speed: float, pitch: float) -> void:
	_hold()
	_speed = speed
	_pitch = pitch
	_effect_changed()

func resetMusicEffect() -> void:
	applyMusicEffect("none")

func resetMusicDistortion() -> void:
	applyMusicDistortion(1.0, 1.0)

func getMusicEffectStateJson() -> String:
	return JSON.stringify({"effect": _effect, "speed": _speed, "pitch": _pitch})

func _effect_changed() -> void:
	music_effect_changed.emit(getMusicEffectStateJson())
	_changed()

func setEqualizer(_bands: PackedVector2Array) -> void:
	pass

func setGraphicEqualizer(_bands: PackedVector2Array, _preamp: float) -> void:
	pass

func setAppVolume(_volume: float) -> void:
	pass

func setNormalizeVolume(_enabled: bool) -> void:
	pass

func setGapless(_enabled: bool) -> void:
	pass

func setDiscord(_settings_json: String) -> void:
	pass

func setSoundFont(_path: String) -> void:
	pass

func setModuleEnding(_enabled: bool) -> void:
	pass

func pickSoundFont() -> void:
	pass

func pickPlugin() -> void:
	pass

func pickTheme() -> void:
	pass

func pickTextFile(_extensions: PackedStringArray) -> void:
	pass

func lastfmKey() -> String:
	return ""

func isReduceMotionEnabled() -> bool:
	return false

func hasNotificationPermission() -> bool:
	return true

func requestNotificationPermission() -> void:
	pass

func hasRecordPermission() -> bool:
	return false

func requestRecordPermission() -> void:
	pass

func getBatteryLevel() -> int:
	return 82

func isBatteryCharging() -> bool:
	return false

func getNetworkStateJson() -> String:
	return JSON.stringify({"connection": "wireless", "level": 4})

func getOutputDeviceJson() -> String:
	return JSON.stringify({"kind": "speaker", "name": "Speaker"})

func getScrobbleAccountsJson() -> String:
	return "{}"

func scrobbleConnect(_service: String) -> void:
	pass

func scrobbleCancel(_service: String) -> void:
	pass

func scrobbleSetToken(_token: String) -> void:
	pass

func scrobbleDisconnect(_service: String) -> void:
	pass

func castScan(_enabled: bool) -> void:
	pass

func getCastDevicesJson() -> String:
	return "[]"

func castConnect(_id: String) -> bool:
	return false

func castDisconnect() -> void:
	pass

func getCastStateJson() -> String:
	return "{}"

func getSoundboardSlotsJson() -> String:
	return "[]"

func getSoundboardFrame() -> PackedByteArray:
	return PackedByteArray()

func setSoundboardActive(_active: bool) -> void:
	pass

func playSound(_slot: int, _recipe: String, _looped: bool) -> void:
	pass

func stopSound(_slot: int) -> void:
	pass

func getSoundWave(_slot: int, _points: int) -> PackedByteArray:
	return PackedByteArray()

func loadEffect(id: int, bytes: PackedByteArray, _name: String) -> void:
	JavaScriptBridge.get_interface("nariSounds").load(id, Marshalls.raw_to_base64(bytes))

func playEffect(id: int, volume: float) -> void:
	JavaScriptBridge.get_interface("nariSounds").play(id, volume)

func deleteSound(_slot: int) -> void:
	pass

func moveSound(_from: int, _to: int) -> bool:
	return false

func startSoundRecording(_song: bool) -> bool:
	return false

func stopSoundRecording() -> void:
	pass

func isSoundRecording() -> bool:
	return false

func importSound() -> void:
	pass

func playPendingSound() -> void:
	pass

func commitPendingSound(_slot: int) -> bool:
	return false

func discardPendingSound() -> void:
	pass

func startSoundEdit(_slot: int, _recipe: String) -> bool:
	return false

func setSoundEditPlaying(_playing: bool) -> void:
	pass

func seekSoundEdit(_position_ms: int) -> void:
	pass

func getSoundEditPositionMs() -> int:
	return 0

func getSoundEditDurationMs() -> int:
	return 0

func stopSoundEdit() -> void:
	pass

func romanizeLines(lines: PackedStringArray) -> PackedStringArray:
	var empty := PackedStringArray()
	empty.resize(lines.size())
	return empty

func rankLyricsJson(_query: String, hits: String) -> String:
	return JSON.stringify({"order": range(JsonUtil.parse_array(hits).size())})

func cleanLyricsJson(lines: String, _title: String, _artists: String) -> String:
	return JSON.stringify({"lines": JsonUtil.parse_array(lines), "instrumental": false, "matched": true})

func vaultSeal(plain: PackedByteArray) -> PackedByteArray:
	return plain

func vaultOpen(sealed: PackedByteArray) -> PackedByteArray:
	return sealed

func isSealed(_uri: String) -> bool:
	return false

func extractPlugin(zip_path: String, target: String) -> String:
	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		return "the file is not a zip archive"
	for file in reader.get_files():
		var relative := file.simplify_path()
		if relative.begins_with("..") or relative.is_absolute_path() or file.ends_with("/"):
			continue
		if not FileUtil.write_bytes(target.path_join(relative), reader.read_file(file)):
			reader.close()
			return "could not write %s" % relative
	reader.close()
	return ""

func analyze(id: int, _uri: String, _options_json: String) -> void:
	job_done.emit.call_deferred(id, JSON.stringify({"error": "the preview has no audio"}))

func saveStream(id: int, _uri: String, _path: String) -> void:
	job_done.emit.call_deferred(id, JSON.stringify({"error": "the preview has no audio"}))

func fileSongJson(_uri: String, _name: String) -> String:
	return "{}"

func isAudioFile(_name: String) -> bool:
	return false

func linksForwarded() -> bool:
	return false

func launchTargets() -> PackedStringArray:
	return PackedStringArray()

func setTrayEnabled(_enabled: bool) -> void:
	pass

func setWindowVisible(_visible: bool) -> bool:
	return false

func updateFlatpak(_id: int) -> void:
	pass

func relaunchFlatpak() -> bool:
	return false

func installApk(_path: String) -> String:
	return ""
