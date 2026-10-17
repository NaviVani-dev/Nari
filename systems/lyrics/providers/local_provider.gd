class_name LocalLyricsProvider extends LyricsProvider

func _init() -> void :
	super ("local", "Local", 100, Color("9ad07a"))
	online = false

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var raw: Dictionary = await MediaPlayer.get_raw_lyrics(str(song.get("id", "")))
	var text: = str(raw.get("text", ""))
	if text.is_empty():
		return found
	var duration: = int(song.get("duration", 0))
	var parsed: = LyricsParser.parse(text, str(raw.get("source", "embedded")), duration, str(raw.get("format", "")))
	if parsed.is_empty():
		return found
	found.append(hit(parsed, str(song.get("title", "")), str(song.get("artist", "")), str(song.get("album", "")), duration))
	return found
