class_name LrclibLyricsProvider extends LyricsProvider

const SEARCH: = "https://lrclib.net/api/search?"

func _init() -> void :
	super ("lrclib", "LRCLIB", 0, Color("7dc1bd"))

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var answer = await get_json(SEARCH + HTTPService.dictionary_to_query({
		"track_name": song.get("title", ""),
		"artist_name": song.get("artist", "")
	}))
	for value in as_array(answer):
		var entry: = as_dict(value)
		var duration: = int(field(entry, "duration").to_float() * 1000.0)
		var lyrics: = _filed(field(entry, "lyricsfile"))
		if lyrics.is_empty():
			lyrics = LyricsParser.parse(field(entry, "syncedLyrics"), "online_lrc", duration, "lrc")
		if lyrics.is_empty():
			lyrics = LyricsParser.parse(field(entry, "plainLyrics"), "online_plain", duration, "txt")
			if not lyrics.is_empty():
				lyrics["format"] = "plain"
				lyrics["synced"] = false
		if lyrics.is_empty():
			continue
		found.append(hit(lyrics, field(entry, "trackName"), field(entry, "artistName"), field(entry, "albumName"),
			duration, bool(entry.get("instrumental", false))))
	_l.log("Result: %d candidates" % found.size())
	return found

func _filed(raw: String) -> Dictionary:
	var service: = native()
	if raw.is_empty() or service == null:
		return {}
	var lines: = JsonUtil.parse_array(service.parseLyricsfileJson(raw))
	return rebuilt(lines, "online_lrclib", display_name) if not lines.is_empty() else {}
