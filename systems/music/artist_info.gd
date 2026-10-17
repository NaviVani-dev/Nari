class_name ArtistInfo extends Node

const CACHE_DIR := "user://artist_info"
const HIT_TTL := 30 * 24 * 3600.0
const MISS_TTL := 7 * 24 * 3600.0
const DEEZER := "https://api.deezer.com"
const LASTFM := "https://ws.audioscrobbler.com/2.0/"
const TOP_SIZE := 10
const MAX_ACTIVE := 2
const VERSION := 1

signal _released

var http := HTTPService.new()
var _memory := {}
var _pending := {}
var _images := {}
var _active := 0
var _key := ""

func _ready() -> void:
	add_child(http)
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var native: Object = Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null
	if native and native.has_method("lastfmKey"):
		_key = native.lastfmKey()

static func enabled() -> bool:
	return SettingsManager.library.artist_info

static var _symbols := RegEx.create_from_string("[\\x00-\\x2f\\x3a-\\x60\\x7b-\\x7f]")

static func key_of(artist_name: String) -> String:
	return _symbols.sub(TextServerManager.get_primary_interface().strip_diacritics(artist_name).to_lower(), "", true)

func cached(artist_name: String) -> Dictionary:
	var key := key_of(artist_name)
	if key.is_empty():
		return {}
	if not _memory.has(key):
		var stored := JsonUtil.parse_dict(FileAccess.get_file_as_string(_path(key, "json"))) if FileAccess.file_exists(_path(key, "json")) else {}
		if int(stored.get("version", 0)) != VERSION:
			stored = {}
		_memory[key] = stored
	return _memory[key]

func info(artist_name: String) -> Dictionary:
	var key := key_of(artist_name)
	if key.is_empty() or not enabled():
		return {}
	var known := cached(artist_name)
	var ttl := HIT_TTL if bool(known.get("found", false)) else MISS_TTL
	if not known.is_empty() and Time.get_unix_time_from_system() - float(known.get("time", 0.0)) < ttl:
		return known if bool(known.get("found", false)) else {}
	var request: MusicProvider.Request = _pending.get(key)
	if request == null:
		request = MusicProvider.Request.new()
		_pending[key] = request
		_fetch(artist_name, key, known, request)
	var found: Dictionary = request.result if request.finished else {}
	if not request.finished:
		found = await request.done
	return found if bool(found.get("found", false)) else {}

func image(artist_name: String, thumb: bool) -> Image:
	var found := await info(artist_name)
	var url := str(found.get("thumb_url" if thumb else "image_url", ""))
	if url.is_empty():
		return null
	var key := key_of(artist_name)
	var file := _path(key + ("_thumb" if thumb else ""), "jpg")
	if FileAccess.file_exists(file):
		var stored: Image = await Worker.run(_load.bind(ProjectSettings.globalize_path(file)))
		if stored and not stored.is_empty():
			return stored
	var request: MusicProvider.Request = _images.get(file)
	if request == null:
		request = MusicProvider.Request.new()
		_images[file] = request
		_download(url, file, request)
	if request.finished:
		return request.result
	return await request.done

func _download(url: String, file: String, request: MusicProvider.Request) -> void:
	await _slot()
	var response := await http.request(url)
	_free_slot()
	var downloaded: Image = null
	if response and response.succeeded():
		downloaded = await Worker.run(_decode.bind(response.body, ProjectSettings.globalize_path(file)))
	_images.erase(file)
	request.finish(downloaded)

static func _load(path: String) -> Image:
	return Image.load_from_file(path)

static func _decode(body: PackedByteArray, path: String) -> Image:
	var decoded := Image.new()
	if decoded.load_jpg_from_buffer(body) != OK:
		return null
	decoded.save_jpg(path, 0.9)
	return decoded

func _fetch(artist_name: String, key: String, known: Dictionary, request: MusicProvider.Request) -> void:
	await _slot()
	var found := {"version": VERSION, "time": Time.get_unix_time_from_system(), "name": artist_name, "found": false}
	var deezer := await _deezer(artist_name, key)
	var lastfm := await _lastfm(artist_name)
	_free_slot()
	if deezer.is_empty() and lastfm.is_empty() and (deezer.has("failed") or lastfm.has("failed")):
		_pending.erase(key)
		request.finish(known)
		return
	found.merge(deezer, true)
	found.merge(lastfm, true)
	found.erase("failed")
	found["found"] = not deezer.is_empty() or not lastfm.is_empty()
	_memory[key] = found
	FileUtil.write_json(_path(key, "json"), found)
	_pending.erase(key)
	request.finish(found)

func _deezer(artist_name: String, key: String) -> Dictionary:
	var response := await http.request("%s/search/artist?q=%s&limit=10" % [DEEZER, artist_name.uri_encode()])
	if not response or not response.succeeded():
		return {"failed": true}
	var best: Dictionary = {}
	for candidate: Variant in response.body_as_dict().get("data", []):
		if candidate is Dictionary and key_of(str(candidate.get("name", ""))) == key:
			best = candidate
			break
	if best.is_empty():
		return {}
	var found := {"fans": int(best.get("nb_fan", 0)), "deezer_id": str(best.get("id", ""))}
	var picture := str(best.get("picture_xl", ""))
	if not picture.is_empty() and not picture.contains("/artist//"):
		found["image_url"] = picture
		found["thumb_url"] = str(best.get("picture_medium", picture))
	var top := await http.request("%s/artist/%s/top?limit=%d" % [DEEZER, found["deezer_id"], TOP_SIZE])
	if top and top.succeeded():
		found["top"] = top.body_as_dict().get("data", []).filter(func(track: Variant) -> bool: return track is Dictionary).map(func(track: Dictionary) -> String: return str(track.get("title", "")))
	return found

func _lastfm(artist_name: String) -> Dictionary:
	if _key.is_empty():
		return {}
	var response := await http.request("%s?method=artist.getinfo&autocorrect=1&format=json&api_key=%s&artist=%s" % [LASTFM, _key, artist_name.uri_encode()])
	if not response or not response.succeeded():
		return {"failed": true}
	var artist: Dictionary = response.body_as_dict().get("artist", {})
	if artist.is_empty():
		return {}
	var stats: Dictionary = artist.get("stats", {})
	var tags: Variant = artist.get("tags", {}).get("tag", []) if artist.get("tags") is Dictionary else []
	var similar: Variant = artist.get("similar", {}).get("artist", []) if artist.get("similar") is Dictionary else []
	return {
		"listeners": int(stats.get("listeners", 0)),
		"plays": int(stats.get("playcount", 0)),
		"bio": _plain(str(artist.get("bio", {}).get("summary", "")) if artist.get("bio") is Dictionary else ""),
		"tags": (tags as Array).map(func(tag: Variant) -> String: return str(tag.get("name", "")) if tag is Dictionary else "") if tags is Array else [],
		"similar": (similar as Array).map(func(entry: Variant) -> String: return str(entry.get("name", "")) if entry is Dictionary else "") if similar is Array else [],
	}

static func _plain(html: String) -> String:
	var cut := html.find("<a href")
	var text := html.left(cut) if cut >= 0 else html
	var tags := RegEx.create_from_string("<[^>]*>")
	return tags.sub(text, "", true).replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'").strip_edges()

func _slot() -> void:
	while _active >= MAX_ACTIVE:
		await _released
	_active += 1

func _free_slot() -> void:
	_active -= 1
	_released.emit()

func _path(key: String, extension: String) -> String:
	return "%s/%s.%s" % [CACHE_DIR, key.md5_text(), extension]
