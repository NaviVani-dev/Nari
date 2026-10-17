class_name AmllLyricsProvider extends LyricsProvider

const SEARCH: = "https://api.amll.dev/v1/lyrics/search?"
const GET: = "https://api.amll.dev/v1/lyrics/get?"

func _init() -> void :
	super ("amll", "AMLL", 150, Color("c58af9"))

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var duration: = int(song.get("duration", 0))
	var title: = str(song.get("title", ""))
	var artist: = str(song.get("artist", ""))
	var isrc: = str(song.get("isrc", ""))
	if not isrc.is_empty():
		var parsed: = await _lyrics({"isrc": isrc}, duration)
		if not parsed.is_empty():
			_l.log("Result: TTML by ISRC | word_synced=%s" % parsed["word_synced"])
			found.append(hit(parsed, title, artist, str(song.get("album", "")), duration))
			return found
	var attempts: = [
		{"musicName": title, "artistName": artist},
		{"musicName": simplify(title), "artistName": lead_artist(artist)},
		{"musicName": simplify(title)}
	]
	var tried: = {}
	for query in attempts:
		if str(query.get("musicName", "")).strip_edges().is_empty():
			continue
		query["pageSize"] = "10"
		var address: = SEARCH + HTTPService.dictionary_to_query(query)
		if tried.has(address):
			continue
		tried[address] = true
		var items: = as_array(as_dict(as_dict(await get_json(address)).get("data")).get("items"))
		for value in items.slice(0, 5):
			var item: = as_dict(value)
			var item_id: = int(item.get("id", -1))
			var names: = as_array(item.get("musicNames"))
			var artists: = as_array(item.get("artistNames"))
			if item_id < 0 or not fits(names, artists, title, artist):
				continue
			var parsed: = await _lyrics({"id": item_id}, duration)
			if parsed.is_empty():
				continue
			_l.log("Result: TTML id=%d | word_synced=%s" % [item_id, parsed["word_synced"]])
			found.append(hit(parsed, title, artist, str(song.get("album", "")), duration))
			return found
	return found

func _lyrics(query: Dictionary, duration: int) -> Dictionary:
	var raw: = str(as_dict(as_dict(await get_json(GET + HTTPService.dictionary_to_query(query))).get("data")).get("lyrics", ""))
	return LyricsParser.parse(raw, "online_ttml", duration, "ttml") if not raw.is_empty() else {}

static func simplify(value: String) -> String:
	var brackets: = RegEx.create_from_string("\\s*[(\\[][^)\\]]*[)\\]]")
	var suffix: = RegEx.create_from_string("\\s+-\\s+.*$")
	return suffix.sub(brackets.sub(value, "", true), "", true).strip_edges()

static func lead_artist(value: String) -> String:
	var separators: = RegEx.create_from_string("(?i)\\s*(,|;|/|\\bfeat\\.?|\\bft\\.?)\\s*")
	return separators.sub(value, "\n", true).get_slice("\n", 0).strip_edges()

static func fits(titles: Array, artists: Array, title: String, artist: String) -> bool:
	if not titles.is_empty() and not titles.any( func(item): return simplify(str(item)).to_lower() == simplify(title).to_lower()):
		return false
	if artist.strip_edges().is_empty() or artists.is_empty():
		return true
	return artists.any( func(item): return str(item).to_lower().contains(artist.to_lower()) or artist.to_lower().contains(str(item).to_lower()))
