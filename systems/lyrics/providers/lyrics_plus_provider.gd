class_name LyricsPlusLyricsProvider extends LyricsProvider

const HOSTS: = ["https://lyricsplus.prjktla.workers.dev", "https://lyricsplus.prjktla.my.id"]

func _init() -> void :
	super ("lyricsplus", "LyricsPlus", 100, Color("f2b05e"))

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var query: = HTTPService.dictionary_to_query({
		"title": song.get("title", ""),
		"artist": song.get("artist", ""),
		"isrc": song.get("isrc", ""),
		"album": song.get("album", ""),
		"duration": int(int(song.get("duration", 0)) / 1000.0)
	})
	var payload: = {}
	for host in HOSTS:
		payload = as_dict(await get_json(host + "/v2/lyrics/get?" + query))
		if not payload.is_empty():
			break
	var converted: = _convert(payload)
	if converted.is_empty():
		_l.log("Result: none")
		return found
	_l.log("Result: %s | word_synced=%s | source=%s" % [converted["format"], converted["word_synced"], converted["origin"]])
	found.append(hit(converted, str(song.get("title", "")), str(song.get("artist", "")), str(song.get("album", "")), int(song.get("duration", 0))))
	return found

func _convert(payload: Dictionary) -> Dictionary:
	var raw = payload.get("lyrics", [])
	if not raw is Array or (raw as Array).is_empty():
		var data = payload.get("data", [])
		raw = data.get("lyrics", []) if data is Dictionary else data
	if not raw is Array or (raw as Array).is_empty():
		return {}
	var line_only: = str(payload.get("type", "")).to_lower() == "line"
	var lines: Array[Dictionary] = []
	for item in raw:
		var entry: = as_dict(item)
		if entry.is_empty():
			continue
		var start: = milliseconds(entry.get("time"), 0)
		var end: = milliseconds(entry.get("endTime"), 0)
		if end <= start:
			end = start + milliseconds(entry.get("duration"), 0)
		var syllables = entry.get("syllabus", entry.get("words", []))
		var main: Array[Dictionary] = []
		var background: Array[Dictionary] = []
		if not line_only and syllables is Array:
			for value in syllables:
				var syllable: = as_dict(value)
				if syllable.is_empty():
					continue
				var segment_start: = milliseconds(syllable.get("time"), start)
				var length: = milliseconds(syllable.get("duration"), 0)
				var built: = LyricsParser.segment(str(syllable.get("text", "")), segment_start,
					segment_start + length if length > 0 else end, bool(syllable.get("part", false)))
				if bool(syllable.get("isBackground", false)):
					background.append(built)
				else:
					main.append(built)
		var text: = str(entry.get("text", ""))
		if text.is_empty():
			text = "".join(main.map( func(segment): return str(segment["text"]))).strip_edges()
		if text.is_empty():
			continue
		if main.is_empty():
			main.append(LyricsParser.segment(text, start, end))
		var transliteration: = as_dict(entry.get("transliteration"))
		var romanized_syllables = transliteration.get("syllabus", [])
		if romanized_syllables is Array and (romanized_syllables as Array).size() == main.size():
			for index in main.size():
				main[index]["romanized_text"] = str(as_dict(romanized_syllables[index]).get("text", ""))
		var element: = as_dict(entry.get("element"))
		var singer: = str(element.get("singer", ""))
		lines.append(LyricsParser.line(start, end, text, main, background,
			str(as_dict(entry.get("translation")).get("text", "")), str(transliteration.get("text", "")),
			str(entry.get("alignment", "end" if singer.ends_with("2") else "start")),
			str(element.get("songPart", "")), singer))
	if lines.is_empty():
		return {}
	lines.sort_custom( func(a, b): return a["start_ms"] < b["start_ms"])
	var word_synced: = lines.any( func(entry): return (entry["segments"] as Array).size() > 1)
	var metadata: = as_dict(payload.get("metadata"))
	var source: = str(metadata.get("source", metadata.get("provider", "")))
	var built: = LyricsParser.build(true, "online_ttml", str(payload.get("language", "")), lines, "ttml" if word_synced else "lrc")
	built["origin"] = source
	var writers = metadata.get("songWriters", [])
	built["songwriters"] = PackedStringArray((writers as Array).map(func(writer): return str(writer))) if writers is Array else PackedStringArray()
	return built
