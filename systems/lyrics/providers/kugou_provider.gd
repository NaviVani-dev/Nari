class_name KugouLyricsProvider extends LyricsProvider

const SEARCH: = "https://mobiles.kugou.com/api/v3/search/song?"
const CANDIDATES: = "https://lyrics.kugou.com/search?"
const DOWNLOAD: = "https://lyrics.kugou.com/download?"
const SONGS: = 4
const SHEETS: = 2

func _init() -> void :
	super ("kugou", "Kugou", 0, Color("2ca2f9"))

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var title: = str(song.get("title", ""))
	var duration_s: = int(int(song.get("duration", 0)) / 1000.0)
	var songs: = as_array(as_dict(as_dict(await get_json(SEARCH + HTTPService.dictionary_to_query({
		"format": "json",
		"keyword": "%s %s" % [song.get("artist", ""), title],
		"page": 1,
		"pagesize": 20,
		"showtype": 1
	}))).get("data")).get("info"))
	songs.sort_custom( func(a, b): return absi(int(as_dict(a).get("duration", 0)) - duration_s) < absi(int(as_dict(b).get("duration", 0)) - duration_s))
	var tasks: Array[Callable] = []
	for value in songs.slice(0, SONGS):
		tasks.append(_sheets.bind(as_dict(value), title))
	for hits in await gather(http, tasks):
		for entry in hits:
			found.append(entry)
	_l.log("Result: %d candidates" % found.size())
	return found

func _sheets(entry: Dictionary, title: String) -> Array[Dictionary]:
	var hits: Array[Dictionary] = []
	var candidates: = as_array(as_dict(await get_json(CANDIDATES + HTTPService.dictionary_to_query({
		"ver": 1,
		"man": "yes",
		"client": "mobi",
		"hash": field(entry, "hash"),
		"duration": int(entry.get("duration", 0)) * 1000
	}))).get("candidates"))
	candidates.sort_custom( func(a, b): return int(as_dict(a).get("krctype", 0)) == 2 and int(as_dict(b).get("krctype", 0)) != 2)
	var singer: = field(entry, "singername")
	var artists: = Array(RegEx.create_from_string("[、,&]").sub(singer, "\n", true).split("\n", false)).map( func(name): return str(name).strip_edges())
	for value in candidates.slice(0, SHEETS):
		var candidate: = as_dict(value)
		var content: = field(as_dict(await get_json(DOWNLOAD + HTTPService.dictionary_to_query({
			"ver": 1,
			"client": "pc",
			"id": field(candidate, "id"),
			"accesskey": field(candidate, "accesskey"),
			"fmt": "krc",
			"charset": "utf8"
		}))), "content")
		var service: = native()
		if content.is_empty() or service == null:
			continue
		var cleaned: = clean(JsonUtil.parse_array(service.decodeKrcJson(content)), title, artists)
		var lines: = as_array(cleaned.get("lines"))
		if not bool(cleaned.get("matched", false)) or bool(cleaned.get("instrumental", false)) or lines.is_empty():
			continue
		hits.append(hit(rebuilt(lines, "online_krc", display_name), field(entry, "songname"), singer, field(entry, "album_name"),
			int(entry.get("duration", 0)) * 1000))
	return hits
