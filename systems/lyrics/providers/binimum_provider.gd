class_name BinimumLyricsProvider extends LyricsProvider

const SEARCH: = "https://lrc.red/api/v1?"

func _init() -> void :
	super ("binimum", "Apple Music", 180, Color("fa586a"))

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var duration: = int(song.get("duration", 0))
	var results: = as_array(as_dict(await get_json(SEARCH + HTTPService.dictionary_to_query({
		"track": song.get("title", ""),
		"artist": song.get("artist", ""),
		"album": song.get("album", ""),
		"duration": int(duration / 1000.0) if duration > 0 else ""
	}))).get("results"))
	results.sort_custom( func(a, b): return _worded(as_dict(a)) and not _worded(as_dict(b)))
	for value in results:
		var match: = as_dict(value)
		var address: = field(match, "lyricsUrl")
		if not address.begins_with("https://"):
			continue
		var response: = await http.request(address)
		if not response or not response.succeeded():
			continue
		var parsed: = LyricsParser.parse(response.body_as_string(), "online_ttml", duration, "ttml")
		if parsed.is_empty():
			continue
		_l.log("Result: TTML | timing=%s | word_synced=%s" % [field(match, "timing_type"), parsed["word_synced"]])
		found.append(hit(parsed, field(match, "track_name"), field(match, "artist_name"), field(match, "album_name"),
			int(float(match.get("duration", 0))) * 1000))
		return found
	_l.log("Result: none")
	return found

func _worded(match: Dictionary) -> bool:
	return field(match, "timing_type") in ["word", "syllable"]
