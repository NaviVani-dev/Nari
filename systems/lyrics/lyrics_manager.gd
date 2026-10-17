class_name LyricsManager extends Node

signal lyrics_ready(song_id: String, lyrics: Dictionary)

const CACHE_DIR: = "user://lyrics"
const CACHE_VERSION: = 4
const MISS_TTL_MS: = 7 * 24 * 60 * 60 * 1000
const LOCAL_MEMO: = 8
const PROVIDERS: = [
	preload("res://systems/lyrics/providers/local_provider.gd"),
	preload("res://systems/lyrics/providers/binimum_provider.gd"),
	preload("res://systems/lyrics/providers/musixmatch_provider.gd"),
	preload("res://systems/lyrics/providers/lrclib_provider.gd"),
	preload("res://systems/lyrics/providers/amll_provider.gd"),
	preload("res://systems/lyrics/providers/lyrics_plus_provider.gd"),
	preload("res://systems/lyrics/providers/kugou_provider.gd"),
	preload("res://systems/lyrics/providers/netease_provider.gd")
]
const PLAIN: = 0
const TIMED: = 1
const WORDED: = 2

var providers: Array[LyricsProvider] = []
var _l: = Log.new("Lyrics", Color("c58af9"))
var _pending: = {}
var _misses: = {}
var _local: = {}

func _ready() -> void :
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	_misses = _read_json(CACHE_DIR + "/misses.json")
	for script in PROVIDERS:
		register(script.new())
	MediaPlayer.library_changed.connect( func(): _local.clear())
	SettingsManager.changed.connect( func(section: String, key: String, _value: Variant):
		if section != "lyrics" or not key in ["providers", "show_romaji"]:
			return
		_local.clear()
		var current: = str(MediaPlayer.get_playback_state().get("current_id", ""))
		if not current.is_empty():
			request(current))

func register(provider: LyricsProvider) -> void :
	provider.http = HTTPService.new()
	if not provider.agent.is_empty():
		provider.http.headers = PackedStringArray(["User-Agent: " + provider.agent])
	add_child(provider.http)
	providers.append(provider)

func unregister(provider: LyricsProvider) -> void :
	providers.erase(provider)
	get_tree().create_timer(HTTPService.TIMEOUT).timeout.connect(provider.http.queue_free)

func searches_online() -> bool:
	return _enabled().any( func(provider: LyricsProvider): return provider.online)

func get_lyrics(song_id: String) -> Dictionary:
	var song: Dictionary = await MediaPlayer.get_song(song_id)
	if song.is_empty():
		return _decorate(LyricsParser.empty(), song_id, 0, false)
	var id: = str(song.get("id", song_id))
	var cached: = _usable_cache(id)
	var lyrics: = as_lyrics(cached.get("hit", {}))
	if lyrics.is_empty():
		lyrics = await _local_lyrics(song, id)
	return _decorate(_romanized(lyrics) if not lyrics.is_empty() else LyricsParser.empty(), id, int(song.get("duration", 0)), _pending.has(id))

func request(song_id: String) -> void :
	var song: Dictionary = await MediaPlayer.get_song(song_id)
	if song.is_empty():
		_l.warn("Search skipped: song not found for id=%s" % song_id)
		return
	var id: = str(song.get("id", song_id))
	if _pending.has(id):
		return
	_pending[id] = true
	_search(song, id)

func _search(song: Dictionary, id: String) -> void :
	var enabled: = _enabled()
	var duration: = int(song.get("duration", 0))
	_l.log("Search started: %s — %s | providers=%s" % [song.get("title", ""), song.get("artist", ""),
		", ".join(enabled.map( func(provider: LyricsProvider): return provider.id))])
	var hits: Array[Dictionary] = []
	var state: = {"displayed": -1, "settled": false, "emitted": {}}
	var cached: = _usable_cache(id)
	var running: = enabled
	if not cached.is_empty():
		hits.append(cached["hit"])
		state["displayed"] = 0
		state["settled"] = _depth(as_lyrics(cached["hit"])) == WORDED
		state["emitted"] = as_lyrics(cached["hit"])
		_emit(id, state["emitted"], duration, true)
		if cached.get("providers", []) == _enabled_ids():
			running = enabled.filter( func(provider: LyricsProvider): return not provider.online)
			_l.log("Cache: %s | re-reading local lyrics only" % cached["hit"].get("provider", ""))
	elif _missed_recently(id):
		running = enabled.filter( func(provider: LyricsProvider): return not provider.online)
		_l.log("Online search skipped: nothing was found recently, will retry in a few days")
	var searched_online: = running.any( func(provider: LyricsProvider): return provider.online)
	var tasks: Array[Callable] = []
	for provider in running:
		tasks.append(func() -> void :
			var found: Array[Dictionary] = []
			found.assign(await provider.search(song))
			_l.log("%s answered with %d hit(s)" % [provider.display_name, found.size()])
			hits.append_array(found)
			_paint(id, song, hits, state))
	await LyricsProvider.gather(self, tasks)

	var ranked: = _rank(song, hits)
	var order: Array = ranked["order"]
	var displayed: int = state["displayed"]
	if displayed >= 0 and order.has(displayed):
		order.erase(displayed)
		order.push_front(displayed)
	var best: = hits[order[0]] if not order.is_empty() else {}
	if searched_online:
		_store_miss(id, order.is_empty())
	if best.is_empty():
		_l.log("Selected lyrics: none")
		_erase_cache(id)
	else:
		_l.log("Selected lyrics: %s | %s | word_synced=%s" % [best.get("provider", ""), as_lyrics(best).get("format", ""), as_lyrics(best).get("word_synced", false)])
		_store(id, best)
	_pending.erase(id)
	_emit(id, as_lyrics(best) if not best.is_empty() else LyricsParser.empty(), duration, false)

func _paint(id: String, song: Dictionary, hits: Array[Dictionary], state: Dictionary) -> void :
	if state["settled"]:
		return
	var order: Array = _rank(song, hits)["order"]
	if order.is_empty():
		return
	var best: Dictionary = hits[order[0]]
	var depth: = _depth(as_lyrics(best))
	if depth == WORDED:
		state["settled"] = true
	elif depth != TIMED or int(state["displayed"]) >= 0:
		return
	state["displayed"] = order[0]
	if as_lyrics(best) == state["emitted"]:
		return
	state["emitted"] = as_lyrics(best)
	_emit(id, state["emitted"], int(song.get("duration", 0)), true)

func _rank(song: Dictionary, hits: Array[Dictionary]) -> Dictionary:
	var service: = LyricsProvider.native()
	if service == null:
		return {"order": range(hits.size())}
	var query: = {
		"title": song.get("title", ""),
		"artist": song.get("artist", ""),
		"album": song.get("album", ""),
		"duration_ms": int(song.get("duration", 0))
	}
	var ranked: = JsonUtil.parse_dict(service.rankLyricsJson(JSON.stringify(query), JSON.stringify(hits)))
	var reshaped: = LyricsProvider.as_dict(ranked.get("reshaped"))
	for key in reshaped:
		var hit: Dictionary = hits[int(key)]
		var lyrics: = as_lyrics(hit)
		hit["lyrics"] = LyricsProvider.rebuilt(reshaped[key], str(lyrics.get("source", "")), str(hit.get("provider", "")), str(lyrics.get("language", "")))
	var order: = []
	for index in LyricsProvider.as_array(ranked.get("order")):
		order.append(int(index))
	return {"order": order}

func _depth(lyrics: Dictionary) -> int:
	if bool(lyrics.get("word_synced", false)):
		return WORDED
	return TIMED if bool(lyrics.get("synced", false)) else PLAIN

func _enabled() -> Array[LyricsProvider]:
	var wanted: = SettingsManager.lyrics.providers
	var enabled: Array[LyricsProvider] = []
	enabled.assign(providers.filter( func(provider: LyricsProvider): return wanted.has(provider.id)))
	return enabled

func _enabled_ids() -> Array:
	var ids: = Array(SettingsManager.lyrics.providers)
	ids.sort()
	return ids

func _romanized(lyrics: Dictionary) -> Dictionary:
	var service: = LyricsProvider.native()
	if not SettingsManager.lyrics.show_romaji or service == null:
		return lyrics
	var lines: Array = lyrics.get("lines", [])
	var texts: = PackedStringArray(lines.map( func(entry): return str(entry.get("text", ""))))
	var romanized: PackedStringArray = service.romanizeLines(texts)
	var result: = lyrics.duplicate(true)
	for index in mini(romanized.size(), lines.size()):
		var entry: Dictionary = result["lines"][index]
		if romanized[index].is_empty() or not str(entry.get("romanized_text", "")).is_empty():
			continue
		entry["romanized_text"] = romanized[index]
		var words: = LyricsParser.split_words(romanized[index])
		var segments: Array = entry.get("segments", [])
		if words.size() != segments.size():
			continue
		for position in segments.size():
			segments[position]["romanized_text"] = words[position] + (" " if str(segments[position]["text"]).ends_with(" ") else "")
	return result

func _local_lyrics(song: Dictionary, id: String) -> Dictionary:
	if not _local.has(id):
		if _local.size() >= LOCAL_MEMO:
			_local.clear()
		var found: Array[Dictionary] = []
		for provider in _enabled():
			if not provider.online:
				found.assign(await provider.search(song))
		_local[id] = as_lyrics(found[0]) if not found.is_empty() else {}
	return _local[id]

func _usable_cache(id: String) -> Dictionary:
	var stored: = _read_json(_cache_path(id))
	var hit: = LyricsProvider.as_dict(stored.get("hit"))
	if hit.is_empty() or int(stored.get("version", 1)) != CACHE_VERSION or not SettingsManager.lyrics.providers.has(str(hit.get("id", ""))):
		return {}
	as_lyrics(hit)["cached"] = true
	return stored

func _store(id: String, hit: Dictionary) -> void :
	var stored: = hit.duplicate(true)
	as_lyrics(stored)["cached"] = false
	_write_json(_cache_path(id), {"version": CACHE_VERSION, "providers": _enabled_ids(), "hit": stored})

func _erase_cache(id: String) -> void :
	if FileAccess.file_exists(_cache_path(id)):
		DirAccess.remove_absolute(_cache_path(id))

func _cache_path(id: String) -> String:
	return "%s/%s.json" % [CACHE_DIR, id.validate_filename()]

func _store_miss(id: String, missed: bool) -> void :
	if not missed and not _misses.has(id):
		return
	if missed:
		_misses[id] = Time.get_unix_time_from_system() * 1000.0
	else:
		_misses.erase(id)
	_write_json(CACHE_DIR + "/misses.json", _misses)

func _missed_recently(id: String) -> bool:
	var at: = float(_misses.get(id, 0.0))
	var elapsed: = Time.get_unix_time_from_system() * 1000.0 - at
	return at > 0.0 and elapsed >= 0.0 and elapsed < MISS_TTL_MS

func _emit(id: String, lyrics: Dictionary, duration_ms: int, loading: bool) -> void :
	lyrics_ready.emit(id, _decorate(_romanized(lyrics) if not lyrics.is_empty() else lyrics, id, duration_ms, loading))

func _decorate(lyrics: Dictionary, id: String, duration_ms: int, loading: bool) -> Dictionary:
	var result: = lyrics.duplicate(true) if not lyrics.is_empty() else LyricsParser.empty()
	result["song_id"] = id
	result["duration_ms"] = duration_ms
	result["loading"] = loading
	return result

static func as_lyrics(hit: Variant) -> Dictionary:
	return LyricsProvider.as_dict(LyricsProvider.as_dict(hit).get("lyrics"))

func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	return JsonUtil.parse_dict(FileAccess.get_file_as_string(path))

func _write_json(path: String, value: Dictionary) -> void :
	if not FileUtil.write_json(path, value):
		_l.error("Could not write '%s'" % path)
