class_name NeteaseLyricsProvider extends LyricsProvider

const SEARCH: = "https://music.163.com/api/search/get?"
const LYRIC: = "https://music.163.com/api/song/lyric/v1?"
const HEADERS: = ["Referer: https://music.163.com"]
const CANDIDATES: = 3

func _init() -> void :
	super ("netease", "NetEase", 0, Color("e72d2c"))

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var duration: = int(song.get("duration", 0))
	var songs: = as_array(as_dict(as_dict(await get_json(SEARCH + HTTPService.dictionary_to_query({
		"s": "%s %s" % [song.get("title", ""), song.get("artist", "")],
		"type": 1,
		"limit": 5
	}), PackedStringArray(HEADERS))).get("result")).get("songs"))
	songs.sort_custom( func(a, b): return absi(int(as_dict(a).get("duration", 0)) - duration) < absi(int(as_dict(b).get("duration", 0)) - duration))
	var tasks: Array[Callable] = []
	for value in songs.slice(0, CANDIDATES):
		tasks.append(_sheet.bind(as_dict(value)))
	for entry in await gather(http, tasks):
		if not (entry as Dictionary).is_empty():
			found.append(entry)
	_l.log("Result: %d candidates" % found.size())
	return found

func _sheet(entry: Dictionary) -> Dictionary:
	var sheet: = as_dict(await get_json(LYRIC + HTTPService.dictionary_to_query({
		"id": field(entry, "id"), "cp": "false", "lv": 0, "tv": 0, "rv": 0, "kv": 0, "yv": 0, "ytv": 0, "yrv": 0
	}), PackedStringArray(HEADERS)))
	if sheet.is_empty() or bool(sheet.get("pureMusic", false)):
		return {}
	var duration: = int(entry.get("duration", 0))
	var lines: = []
	var yrc: = field(as_dict(sheet.get("yrc")), "lyric")
	var service: = native()
	if not yrc.strip_edges().is_empty() and service != null:
		lines = JsonUtil.parse_array(service.parseYrcJson(yrc))
	if lines.is_empty():
		lines = as_array(LyricsParser.parse(field(as_dict(sheet.get("lrc")), "lyric"), "online_lrc", duration, "lrc").get("lines"))
	if lines.is_empty():
		return {}
	var artists: = as_array(entry.get("artists")).map( func(artist): return field(as_dict(artist), "name"))
	var cleaned: = clean(lines, field(entry, "name"), artists)
	lines = as_array(cleaned.get("lines"))
	if not bool(cleaned.get("matched", false)) or bool(cleaned.get("instrumental", false)) or lines.is_empty():
		return {}
	return hit(rebuilt(lines, "online_netease", display_name), field(entry, "name"), ", ".join(artists), field(as_dict(entry.get("album")), "name"), duration)
