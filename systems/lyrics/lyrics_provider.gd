class_name LyricsProvider extends RefCounted

var id: = ""
var display_name: = ""
var trust: = 0
var online: = true
var agent: = ""
var http: HTTPService
var _l: Log

func _init(provider_id: String, name: String, provider_trust: int, color: Color) -> void :
	id = provider_id
	display_name = name
	trust = provider_trust
	_l = Log.new(name, color)

func search(_song: Dictionary) -> Array[Dictionary]:
	return []

func hit(lyrics: Dictionary, title: String, artist: String, album: String, duration_ms: int, instrumental: bool = false) -> Dictionary:
	lyrics["provider"] = display_name
	return {
		"id": id,
		"provider": display_name,
		"trust": trust,
		"title": title,
		"artist": artist,
		"album": album,
		"duration_ms": duration_ms,
		"instrumental": instrumental,
		"lyrics": lyrics
	}

static func rebuilt(lines: Array, source: String, provider: String, language: String = "") -> Dictionary:
	var synced: = not lines.is_empty() and int(lines[0].get("start_ms", -1)) >= 0
	var built: = LyricsParser.build(synced, source, language, lines, "plain")
	built["format"] = "ttml" if built["word_synced"] else ("lrc" if synced else "plain")
	built["provider"] = provider
	return built

func get_json(address: String, headers: = PackedStringArray()) -> Variant:
	var response: = await http.request(address, headers)
	if not response or not response.succeeded():
		return null
	return JSON.parse_string(response.body_as_string())

static func native() -> Object:
	return Engine.get_singleton("MusicService") if Engine.has_singleton("MusicService") else null

static func gather(node: Node, tasks: Array[Callable]) -> Array:
	var results: = []
	results.resize(tasks.size())
	var left: = [tasks.size()]
	for index in tasks.size():
		var run: = func(at: int) -> void :
			results[at] = await tasks[at].call()
			left[0] -= 1
		run.call(index)
	while left[0] > 0:
		await node.get_tree().process_frame
	return results

func clean(lines: Array, title: String, artists: Array) -> Dictionary:
	var service: = native()
	if service == null:
		return {"lines": lines, "instrumental": false, "matched": true}
	return JsonUtil.parse_dict(service.cleanLyricsJson(JSON.stringify(lines), title, JSON.stringify(artists)))

static func field(entry: Dictionary, key: String) -> String:
	var value = entry.get(key)
	if value == null:
		return ""
	if value is float and is_equal_approx(fmod(value, 1.0), 0.0) and absf(value) < 9.0e15:
		return str(int(value))
	return str(value)

static func as_dict(value: Variant) -> Dictionary:
	return value if value is Dictionary else {}

static func as_array(value: Variant) -> Array:
	return value if value is Array else []

static func milliseconds(value: Variant, fallback: int) -> int:
	var number: = 0.0
	if value is float or value is int:
		number = float(value)
	elif value is String and (value as String).is_valid_float():
		number = (value as String).to_float()
	else:
		return fallback
	return maxi(int(number if is_equal_approx(fmod(number, 1.0), 0.0) else number * 1000.0), 0)
