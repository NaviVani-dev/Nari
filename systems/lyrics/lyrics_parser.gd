class_name LyricsParser extends RefCounted

const AUXILIARY_ROLES: = ["x-translation", "x-transliteration", "x-romanization", "x-roman"]
const IGNORED_TAGS: = ["ar", "al", "au", "by", "length", "re", "ti", "ve"]
const ENTITIES: = {"&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&nbsp;": " "}

static var _timestamp: = RegEx.create_from_string("\\[(?:(\\d+):)?(\\d+):([0-5]?\\d)(?:[.:](\\d{1,3}))?\\]")
static var _word_timestamp: = RegEx.create_from_string("<(?:(\\d+):)?(\\d+):([0-5]?\\d)(?:[.:](\\d{1,3}))?>")
static var _metadata: = RegEx.create_from_string("^\\[([A-Za-z]+):(.*)\\]$")
static var _spaces: = RegEx.create_from_string("\\s+")
static var _gap_between_tags: = RegEx.create_from_string(">[ \\t]+<")

static func empty(source: String = "") -> Dictionary:
	return build(false, source, "", [], "plain")

static func segment(text: String, start_ms: int, end_ms: int, part: bool = false, romanized_text: String = "") -> Dictionary:
	return {
		"text": text,
		"start_ms": start_ms,
		"end_ms": end_ms,
		"part": part,
		"romanized_text": romanized_text
	}

static func line(start_ms: int, end_ms: int, text: String, segments: Array = [], background_segments: Array = [],
		translation: String = "", romanized_text: String = "", alignment: String = "start",
		song_part: String = "", agent_id: String = "") -> Dictionary:
	return {
		"start_ms": start_ms,
		"end_ms": end_ms,
		"text": text,
		"segments": segments,
		"background_segments": background_segments,
		"translation": translation if translation.strip_edges() != text.strip_edges() else "",
		"romanized_text": romanized_text if non_latin(text) else "",
		"alignment": alignment,
		"song_part": song_part,
		"agent_id": agent_id
	}

static func build(synced: bool, source: String, language: String, lines: Array, format: String, provider: String = "") -> Dictionary:
	var texts: = PackedStringArray()
	var word_synced: = false
	for entry in lines:
		texts.append(str(entry.get("text", "")))
		if (entry.get("segments", []) as Array).size() > 1:
			word_synced = true
	return {
		"found": not lines.is_empty(),
		"synced": synced,
		"word_synced": word_synced,
		"format": format,
		"source": source,
		"provider": provider,
		"cached": false,
		"language": language,
		"text": "\n".join(texts),
		"lines": lines
	}

static func parse(raw: String, source: String, duration_ms: int = 0, extension: String = "") -> Dictionary:
	var normalized: = raw.trim_prefix("").replace("\r\n", "\n").replace("\r", "\n").strip_edges()
	if normalized.is_empty():
		return {}
	if extension.to_lower() == "ttml" or (normalized.contains("<tt") and normalized.contains("<p")):
		return parse_ttml(normalized, source)
	var language: = ""
	var offset: = 0
	var timed: Array[Dictionary] = []
	var plain: = PackedStringArray()
	for original in normalized.split("\n"):
		var entry: = original.rstrip(" \t")
		var info: = _metadata.search(entry)
		if info and info.get_end(0) == entry.length():
			var tag: = info.get_string(1).to_lower()
			if tag == "offset":
				offset = info.get_string(2).strip_edges().to_int()
			elif tag == "la" or tag == "lang" or tag == "language":
				language = info.get_string(2).strip_edges()
			elif not IGNORED_TAGS.has(tag):
				plain.append(entry)
			continue
		var stamps: = _timestamp.search_all(entry)
		if stamps.is_empty():
			plain.append(entry)
			continue
		var without_stamps: = _timestamp.sub(entry, "", true)
		var words: = _word_timestamp.search_all(without_stamps)
		var clean: = _word_timestamp.sub(without_stamps, "", true).strip_edges()
		for stamp in stamps:
			var segments: Array[Dictionary] = []
			for index in words.size():
				var start: = words[index].get_end(0)
				var end: = words[index + 1].get_start(0) if index + 1 < words.size() else without_stamps.length()
				segments.append(segment(without_stamps.substr(start, end - start), _stamp_to_ms(words[index]), -1))
			timed.append({"start_ms": _stamp_to_ms(stamp), "text": clean, "segments": segments})
	if not timed.is_empty():
		return _timed_lines(timed, offset, duration_ms, source, language)
	var text: = "\n".join(plain).strip_edges()
	if text.is_empty():
		return {}
	var lines: Array[Dictionary] = []
	for entry in text.split("\n"):
		lines.append(line(-1, -1, entry))
	return build(false, source, language, lines, "plain")

static func parse_ttml(raw: String, source: String, provider: String = "") -> Dictionary:
	var parser: = XMLParser.new()
	if parser.open_buffer(_gap_between_tags.sub(raw, ">&nbsp;<", true).to_utf8_buffer()) != OK:
		return {}
	var reader: = TtmlReader.new()
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				var name: = _local_name(parser.get_node_name())
				reader.open(name, parser)
				if parser.is_empty():
					reader.close(name)
			XMLParser.NODE_ELEMENT_END:
				reader.close(_local_name(parser.get_node_name()))
			XMLParser.NODE_TEXT, XMLParser.NODE_CDATA:
				reader.write(_decode_entities(parser.get_node_data()))
	if reader.lines.is_empty():
		return {}
	var built: = build(true, source, reader.language, reader.finish(), "ttml", provider)
	built["songwriters"] = reader.songwriters
	return built


static func time_to_ms(value: String) -> int:
	if value.is_empty():
		return -1
	if value.ends_with("ms"):
		return int(_to_number(value.left(value.length() - 2)))
	if value.ends_with("s"):
		return int(_to_number(value.left(value.length() - 1)) * 1000.0)
	var parts: = value.split(":")
	if parts.size() == 3:
		return int(_to_number(parts[0]) * 3600000.0 + _to_number(parts[1]) * 60000.0 + _to_number(parts[2]) * 1000.0)
	if parts.size() == 2:
		return int(_to_number(parts[0]) * 60000.0 + _to_number(parts[1]) * 1000.0)
	return int(_to_number(value) * 1000.0) if value.is_valid_float() else -1

static func non_latin(text: String) -> bool:
	for index in text.length():
		var code: = text.unicode_at(index)
		if (code >= 0x0370 and code < 0x2000) or (code >= 0x2E80 and code < 0xD800) or (code >= 0xF900 and code < 0xFB00):
			return true
	return false

static func split_words(value: String) -> PackedStringArray:
	return _spaces.sub(value, " ", true).strip_edges().split(" ", false)


static func _timed_lines(timed: Array[Dictionary], offset: int, duration_ms: int, source: String, language: String) -> Dictionary:
	var seen: = {}
	var ordered: Array[Dictionary] = []
	for entry in timed:
		entry["start_ms"] = maxi(entry["start_ms"] + offset, 0)
		var key: = "%d %s" % [entry["start_ms"], entry["text"]]
		if not seen.has(key):
			seen[key] = true
			ordered.append(entry)
	ordered.sort_custom( func(a, b): return a["start_ms"] < b["start_ms"])
	var lines: Array[Dictionary] = []
	for index in ordered.size():
		var entry: = ordered[index]
		var end: = -1
		for next_index in range(index + 1, ordered.size()):
			if ordered[next_index]["start_ms"] > entry["start_ms"]:
				end = ordered[next_index]["start_ms"]
				break
		if end < 0 and duration_ms > int(entry["start_ms"]):
			end = duration_ms
		var segments: Array[Dictionary] = []
		var source_segments: Array = entry["segments"]
		for segment_index in source_segments.size():
			var current: Dictionary = source_segments[segment_index]
			var segment_end: = end
			if segment_index + 1 < source_segments.size():
				segment_end = maxi(int(source_segments[segment_index + 1]["start_ms"]) + offset, 0)
			segments.append(segment(current["text"], maxi(int(current["start_ms"]) + offset, 0), segment_end))
		lines.append(line(entry["start_ms"], end, entry["text"], segments))
	return build(true, source, language, lines, "lrc")

static func _stamp_to_ms(stamp: RegExMatch) -> int:
	var fraction: = stamp.get_string(4)
	var milliseconds: = 0
	if fraction.length() == 1:
		milliseconds = fraction.to_int() * 100
	elif fraction.length() == 2:
		milliseconds = fraction.to_int() * 10
	elif fraction.length() == 3:
		milliseconds = fraction.to_int()
	return stamp.get_string(1).to_int() * 3600000 + stamp.get_string(2).to_int() * 60000 + stamp.get_string(3).to_int() * 1000 + milliseconds

static func _local_name(name: String) -> String:
	return name.get_slice(":", 1) if name.contains(":") else name

static func _decode_entities(value: String) -> String:
	if not value.contains("&"):
		return value
	var decoded: = value
	for entity in ENTITIES:
		decoded = decoded.replace(entity, ENTITIES[entity])
	return decoded

static func _to_number(value: String) -> float:
	return value.to_float() if value.is_valid_float() else 0.0

class TtmlReader extends RefCounted:
	var lines: Array[Dictionary] = []
	var language: = ""
	var songwriters: = PackedStringArray()

	var _song_part: = ""
	var _in_songwriter: = false
	var _in_line: = false
	var _line_start: = -1
	var _line_end: = -1
	var _line_key: = ""
	var _agent_id: = ""
	var _segments: Array[Dictionary] = []
	var _backgrounds: Array[Dictionary] = []
	var _span_depth: = 0
	var _background_depth: = 0
	var _segment_start: = -1
	var _segment_end: = -1
	var _segment_background: = false
	var _segment_text: = ""
	var _between_text: = ""
	var _last_segment: = {}
	var _direct_text: = ""
	var _auxiliary_depth: = 0
	var _auxiliary_kind: = ""
	var _auxiliary_text: = ""
	var _inline_translation: = ""
	var _inline_romanization: = ""
	var _translations: = {}
	var _romanizations: = {}
	var _metadata_kind: = ""
	var _metadata_for: = ""

	func open(name: String, parser: XMLParser) -> void :
		if name == "songwriter":
			_in_songwriter = true
			songwriters.append("")
		if name == "tt":
			language = _attribute(parser, "lang")
		if name == "div":
			_song_part = _attribute(parser, "songPart")
		if not _in_line and (name == "translation" or name == "transliteration"):
			_metadata_kind = name
		if not _in_line and name == "text" and not _metadata_kind.is_empty():
			_metadata_for = _attribute(parser, "for")
		if name == "p":
			_in_line = true
			_line_start = LyricsParser.time_to_ms(_attribute(parser, "begin"))
			_line_end = LyricsParser.time_to_ms(_attribute(parser, "end"))
			_line_key = _attribute(parser, "key")
			_agent_id = _attribute(parser, "agent")
			_segments = []
			_backgrounds = []
			_direct_text = ""
			_between_text = ""
			_last_segment = {}
			_auxiliary_depth = 0
			_auxiliary_kind = ""
			_auxiliary_text = ""
			_inline_translation = ""
			_inline_romanization = ""
		elif _in_line and name == "span":
			var role: = _attribute(parser, "role")
			_span_depth += 1
			if _auxiliary_depth == 0 and LyricsParser.AUXILIARY_ROLES.has(role):
				_auxiliary_depth = _span_depth
				_auxiliary_kind = role
				_auxiliary_text = ""
			elif _auxiliary_depth == 0 and role == "x-bg":
				_background_depth += 1
			if _auxiliary_depth == 0 and ( not _attribute(parser, "begin").is_empty() or _span_depth == 1):
				_segment_background = _background_depth > 0
				_segment_start = LyricsParser.time_to_ms(_attribute(parser, "begin"))
				_segment_end = LyricsParser.time_to_ms(_attribute(parser, "end"))
				if _segment_start < 0:
					_segment_start = _line_start
				if _segment_end < 0:
					_segment_end = _line_end
				if not _last_segment.is_empty() and not _between_text.is_empty():
					_last_segment["text"] = str(_last_segment["text"]) + _between_text
					_last_segment["part"] = not str(_last_segment["text"]).ends_with(" ")
				_segment_text = ""
				_between_text = ""

	func write(value: String) -> void :
		if _in_songwriter:
			songwriters[-1] += value
		if _in_line:
			if _auxiliary_depth > 0:
				_auxiliary_text += value
			else:
				_direct_text += value
				if _segment_start >= 0:
					_segment_text += value
				elif not _last_segment.is_empty():
					_between_text += value
		elif not _metadata_for.is_empty():
			if _metadata_kind == "translation":
				_translations[_metadata_for] = str(_translations.get(_metadata_for, "")) + value
			if _metadata_kind == "transliteration":
				_romanizations[_metadata_for] = str(_romanizations.get(_metadata_for, "")) + value

	func close(name: String) -> void :
		if name == "songwriter":
			_in_songwriter = false
			songwriters[-1] = songwriters[-1].strip_edges()
		if _in_line and name == "span":
			if _auxiliary_depth > 0:
				if _span_depth == _auxiliary_depth:
					if _auxiliary_kind == "x-translation":
						_inline_translation = _auxiliary_text.strip_edges()
					else:
						_inline_romanization = _auxiliary_text.strip_edges()
					_auxiliary_depth = 0
					_auxiliary_kind = ""
					_auxiliary_text = ""
				_span_depth -= 1
			else:
				if _segment_start >= 0 and _span_depth == 1 + (1 if _background_depth > 0 else 0):
					if not _segment_text.strip_edges().is_empty():
						var entry: = LyricsParser.segment(_segment_text, _segment_start, maxi(_segment_end, _segment_start), not _segment_text.ends_with(" "))
						if _segment_background:
							_backgrounds.append(entry)
						else:
							_segments.append(entry)
						_last_segment = entry
					_segment_start = -1
				_span_depth -= 1
				if _background_depth > 0 and _span_depth == 0:
					_background_depth -= 1
		if name == "p" and _in_line:
			var text: = _direct_text.strip_edges()
			if not _segments.is_empty():
				text = "".join(_segments.map( func(entry): return str(entry["text"]))).strip_edges()
			if not text.is_empty():
				var main: = _segments
				if main.is_empty():
					main = [LyricsParser.segment(text, _line_start, _line_end)]
				var romanized: = _inline_romanization if not _inline_romanization.is_empty() else str(_romanizations.get(_line_key, "")).strip_edges()
				lines.append(LyricsParser.line(_line_start, _line_end, text, main, _backgrounds,
					_inline_translation if not _inline_translation.is_empty() else str(_translations.get(_line_key, "")).strip_edges(),
					romanized, "start", _song_part, _agent_id))
			_in_line = false
		if not _in_line and name == "text":
			_metadata_for = ""
		if not _in_line and (name == "translation" or name == "transliteration"):
			_metadata_kind = ""

	func finish() -> Array[Dictionary]:
		var agents: = PackedStringArray()
		for entry in lines:
			var agent: = str(entry["agent_id"])
			if not agent.is_empty() and not agents.has(agent):
				agents.append(agent)
		lines.sort_custom( func(a, b): return a["start_ms"] < b["start_ms"])
		for entry in lines:
			var agent_index: = agents.find(str(entry["agent_id"]))
			entry["alignment"] = "end" if agent_index > 0 and agent_index % 2 == 1 else "start"
			var segments: Array = entry["segments"]
			var words: = LyricsParser.split_words(str(entry["romanized_text"]))
			if words.size() != segments.size():
				continue
			if not segments.all( func(item): return str(item["romanized_text"]).is_empty()):
				continue
			for index in segments.size():
				segments[index]["romanized_text"] = words[index] + (" " if str(segments[index]["text"]).ends_with(" ") else "")
		return lines

	func _attribute(parser: XMLParser, name: String) -> String:
		for index in parser.get_attribute_count():
			if LyricsParser._local_name(parser.get_attribute_name(index)) == name:
				return LyricsParser._decode_entities(parser.get_attribute_value(index))
		return ""
