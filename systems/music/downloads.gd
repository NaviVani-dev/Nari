class_name Downloads extends RefCounted

signal changed(song_id: String)
signal queue_changed
signal finished(song_id: String, success: bool)

const ROOT: = "user://downloads"

var _indexes: Dictionary = {}
var _pending: Dictionary = {}
var _queue: Array[Dictionary] = []
var _active: Dictionary = {}
var _request: HTTPRequest
var _l: = Log.new("Downloads", Color("8fd18b"))

func has(provider_id: String, song_id: String) -> bool:
	return _index(provider_id).has(song_id)

func is_pending(provider_id: String, song_id: String) -> bool:
	return _pending.has(provider_id + ":" + song_id)

func path(provider_id: String, song_id: String) -> String:
	var entry: Dictionary = _index(provider_id).get(song_id, {})
	return ProjectSettings.globalize_path(_dir(provider_id).path_join(str(entry["file"]))) if not entry.is_empty() else ""

func track(provider_id: String, song_id: String) -> Dictionary:
	var entry: Dictionary = _index(provider_id).get(song_id, {})
	return entry.get("track", {})

func tracks(provider_id: String) -> Array:
	var found: = _index(provider_id).values().map(func(entry: Dictionary): return entry["track"])
	found.sort_custom(func(first: Dictionary, second: Dictionary): return str(first.get("sort_title", "")) < str(second.get("sort_title", "")))
	return found

func active_track() -> Dictionary:
	return _active.get("song", {})

func remaining() -> int:
	return _queue.size() + (0 if _active.is_empty() else 1)

func progress() -> float:
	if not is_instance_valid(_request):
		return 0.0
	var total: = float(_request.get_body_size())
	if total <= 0.0:
		total = float(_active.get("estimate", 0))
	return clampf(_request.get_downloaded_bytes() / total, 0.0, 1.0) if total > 0.0 else 0.0

func download(provider: MusicProvider, song: Dictionary) -> bool:
	var song_id: = str(song.get("id", ""))
	var key: = provider.id + ":" + song_id
	if song_id.is_empty() or has(provider.id, song_id) or _pending.has(key):
		return false
	_pending[key] = true
	_queue.append({"provider": provider, "song": song})
	changed.emit(song_id)
	queue_changed.emit()
	if _active.is_empty():
		_work()
	while true:
		var result: Array = await finished
		if result[0] == song_id:
			return result[1]
	return false

func _work() -> void :
	while not _queue.is_empty():
		_active = _queue.pop_front()
		queue_changed.emit()
		var song_id: = str(_active["song"].get("id", ""))
		var done: bool = await _fetch(_active["provider"], _active["song"])
		_active = {}
		_request = null
		finished.emit(song_id, done)
	queue_changed.emit()

func _fetch(provider: MusicProvider, song: Dictionary) -> bool:
	var song_id: = str(song.get("id", ""))
	var key: = provider.id + ":" + song_id
	var quality: String = SettingsManager.playback.download_quality
	var uri: = provider.media_uri(song, quality)
	if uri.is_empty():
		var playable: Array = await provider.playable([song])
		uri = str(playable[0].get("uri", "")) if not playable.is_empty() else ""
	var extension: = "mp3" if provider.transcodes(quality) else str(song.get("file_name", "")).get_extension()
	if MediaPlayer.is_sealed(uri):
		uri += "?save"
		extension = "sealed"
	var file: = "%s.%s" % [song_id.validate_filename(), extension if not extension.is_empty() else "mp3"]
	var target: = _dir(provider.id).path_join(file)
	DirAccess.make_dir_recursive_absolute(_dir(provider.id))
	var kbps: int = MusicProvider.BITRATES.get(quality, 0) if provider.transcodes(quality) else int(song.get("bitrate", 0))
	_active["estimate"] = int(float(song.get("duration", 0)) / 1000.0 * kbps * 125.0)
	var done: = false
	if uri.begins_with("http://") or uri.begins_with("https://"):
		done = await provider.http.download(uri, target + ".part", PackedStringArray(), func(request: HTTPRequest): _request = request)
	elif not uri.is_empty():
		var saved: Dictionary = await MediaPlayer.save_stream(uri, ProjectSettings.globalize_path(target + ".part"))
		done = bool(saved.get("ok", false))
		if not done:
			_l.warn("Could not save '%s': %s" % [song.get("title", song_id), saved.get("error", "")])
	if done:
		done = DirAccess.rename_absolute(target + ".part", target) == OK
	else:
		DirAccess.remove_absolute(target + ".part")
	if done:
		_index(provider.id)[song_id] = {"file": file, "track": song}
		_save(provider.id)
		_l.log("Downloaded '%s'" % song.get("title", song_id))
	else:
		_l.warn("Could not download '%s'" % song.get("title", song_id))
	_pending.erase(key)
	changed.emit(song_id)
	return done

func remove(provider_id: String, song_id: String) -> void :
	var entry: Dictionary = _index(provider_id).get(song_id, {})
	if entry.is_empty():
		return
	DirAccess.remove_absolute(_dir(provider_id).path_join(str(entry["file"])))
	_index(provider_id).erase(song_id)
	_save(provider_id)
	changed.emit(song_id)

func _dir(provider_id: String) -> String:
	return ROOT.path_join(provider_id.validate_filename())

func _index(provider_id: String) -> Dictionary:
	if not _indexes.has(provider_id):
		var saved: = FileAccess.get_file_as_string(_dir(provider_id).path_join("index.json"))
		_indexes[provider_id] = JsonUtil.parse_dict(saved) if not saved.is_empty() else {}
	return _indexes[provider_id]

func _save(provider_id: String) -> void :
	FileUtil.write_json(_dir(provider_id).path_join("index.json"), _index(provider_id))
