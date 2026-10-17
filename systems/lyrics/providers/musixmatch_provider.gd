class_name MusixmatchLyricsProvider extends LyricsProvider

const TOKEN: = "https://apic.musixmatch.com/ws/1.1/token.get?"
const SUBTITLES: = "https://apic.musixmatch.com/ws/1.1/macro.subtitles.get?"
const APP: = "mac-ios-v2.0"
const BROWSER: = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
const HEADERS: = ["Cookie: x-mxm-token-guid="]
const TOKEN_FILE: = "user://lyrics/musixmatch_ios.json"
const SPACING_MS: = 1500
const COOLDOWN_MS: = 600000
const THROTTLED: = [401, 402, 403, 429]

static var _token: = ""
static var _latest: = -SPACING_MS
static var _blocked_until: = 0

func _init() -> void :
	super ("musixmatch", "Musixmatch", 35, Color("ff6050"))
	agent = BROWSER

func search(song: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var calls: = await _lookup(song)
	if calls.is_empty():
		return found
	var track: = as_dict(_answered(calls, "matcher.track.get").get("track"))
	if track.is_empty() or int(track.get("instrumental", 0)) == 1:
		_l.log("Result: %s" % ("instrumental" if not track.is_empty() else "no match"))
		return found
	var duration: = int(track.get("track_length", 0)) * 1000
	var lines: = _richsync(calls)
	var kind: = "richsync"
	if lines.is_empty():
		lines = _subtitles(calls, duration)
		kind = "subtitles"
	if lines.is_empty():
		_l.log("Result: matched without synced lyrics")
		return found
	var lyrics: = rebuilt(lines, "online_musixmatch", display_name)
	_l.log("Result: %s | %d lines | word_synced=%s" % [kind, lines.size(), lyrics["word_synced"]])
	found.append(hit(lyrics, field(track, "track_name"), field(track, "artist_name"), field(track, "album_name"), duration))
	return found

func _lookup(song: Dictionary) -> Dictionary:
	var query: = {
		"format": "json",
		"namespace": "lyrics_richsynched",
		"subtitle_format": "mxm",
		"optional_calls": "track.richsync",
		"app_id": APP,
		"q_track": song.get("title", ""),
		"q_artist": song.get("artist", ""),
		"q_album": song.get("album", ""),
		"q_duration": int(int(song.get("duration", 0)) / 1000.0) if int(song.get("duration", 0)) > 0 else ""
	}
	for renewed in [false, true]:
		if not await _wait():
			_l.log("Skipped: cooling down after being throttled")
			return {}
		var token: = ""
		if renewed:
			token = await _renew()
		else:
			token = await _current_token()
		if token.is_empty():
			return {}
		query["usertoken"] = token
		var message: = as_dict(as_dict(await get_json(SUBTITLES + HTTPService.dictionary_to_query(query), PackedStringArray(HEADERS))).get("message"))
		var header: = as_dict(message.get("header"))
		var status: = int(header.get("status_code", 0))
		if status == 200:
			return as_dict(as_dict(message.get("body")).get("macro_calls"))
		if status == 401 and str(header.get("hint", "")) == "renew":
			continue
		if THROTTLED.has(status):
			_block()
			_l.warn("Throttled (%d, %s)" % [status, header.get("hint", "no hint")])
			return {}
		if status != 404:
			_l.warn("Answered with status %d" % status)
		return {}
	_l.warn("Keeps rejecting the token")
	return {}

func _wait() -> bool:
	var now: = Time.get_ticks_msec()
	if now < _blocked_until:
		return false
	var slot: = maxi(now, _latest + SPACING_MS)
	_latest = slot
	if slot > now:
		await http.get_tree().create_timer((slot - now) / 1000.0).timeout
	return Time.get_ticks_msec() >= _blocked_until

func _block() -> void :
	_blocked_until = Time.get_ticks_msec() + COOLDOWN_MS

func _current_token() -> String:
	if not _token.is_empty():
		return _token
	if FileAccess.file_exists(TOKEN_FILE):
		_token = str(JsonUtil.parse_dict(Vault.load_text(TOKEN_FILE)).get("user_token", ""))
		if _token.replace("0", "").is_empty():
			_token = ""
	if not _token.is_empty():
		return _token
	return await _renew()

func _renew() -> String:
	_token = ""
	var message: = as_dict(as_dict(await get_json(TOKEN + HTTPService.dictionary_to_query({"format": "json", "app_id": APP}), PackedStringArray(HEADERS))).get("message"))
	var status: = int(as_dict(message.get("header")).get("status_code", 0))
	if THROTTLED.has(status):
		_block()
		_l.warn("Throttled while asking for a token (%d)" % status)
		return ""
	var token: = str(as_dict(message.get("body")).get("user_token", ""))
	if status == 200 and not token.is_empty() and token.replace("0", "").is_empty():
		_block()
		_l.warn("Handed out a placeholder token, this network is being refused")
		return ""
	if status != 200 or token.is_empty() or token.contains("UpgradeOnly"):
		_l.warn("Handed out no token (status %d)" % status)
		return ""
	_token = token
	Vault.save_text(TOKEN_FILE, JSON.stringify({"user_token": token}))
	return token

func _answered(calls: Dictionary, name: String) -> Dictionary:
	var message: = as_dict(as_dict(calls.get(name)).get("message"))
	if int(as_dict(message.get("header")).get("status_code", 0)) != 200:
		return {}
	return as_dict(message.get("body"))

func _richsync(calls: Dictionary) -> Array[Dictionary]:
	var lines: Array[Dictionary] = []
	var body: = field(as_dict(_answered(calls, "track.richsync.get").get("richsync")), "richsync_body")
	if body.is_empty():
		return lines
	for value in as_array(JSON.parse_string(body)):
		var sung: = as_dict(value)
		var start: = int(float(sung.get("ts", 0.0)) * 1000.0)
		var end: = maxi(int(float(sung.get("te", 0.0)) * 1000.0), start)
		var tokens: = as_array(sung.get("l"))
		var segments: Array[Dictionary] = []
		for index in tokens.size():
			var token: = as_dict(tokens[index])
			var text: = field(token, "c")
			var opened: = start + int(float(token.get("o", 0.0)) * 1000.0)
			var closed: = end if index + 1 >= tokens.size() else start + int(float(as_dict(tokens[index + 1]).get("o", 0.0)) * 1000.0)
			closed = maxi(closed, opened)
			if not segments.is_empty() and text.strip_edges().is_empty():
				segments[-1]["text"] += text
				segments[-1]["end_ms"] = maxi(int(segments[-1]["end_ms"]), closed)
				continue
			segments.append(LyricsParser.segment(text, opened, closed))
		var text: = field(sung, "x")
		if text.strip_edges().is_empty():
			continue
		lines.append(LyricsParser.line(start, end, text, segments))
	return lines

func _subtitles(calls: Dictionary, duration: int) -> Array[Dictionary]:
	var lines: Array[Dictionary] = []
	var list: = as_array(_answered(calls, "track.subtitles.get").get("subtitle_list"))
	if list.is_empty():
		return lines
	var body: = field(as_dict(as_dict(list[0]).get("subtitle")), "subtitle_body").strip_edges()
	if body.is_empty():
		return lines
	var cues: = as_array(JSON.parse_string(body)) if body.begins_with("[{") else []
	if cues.is_empty():
		var parsed: = LyricsParser.parse(body, "online_musixmatch", duration, "lrc")
		for entry in as_array(parsed.get("lines")):
			lines.append(entry)
		return lines
	for index in cues.size():
		var cue: = as_dict(cues[index])
		var start: = int(float(as_dict(cue.get("time")).get("total", 0.0)) * 1000.0)
		var end: = int(float(as_dict(as_dict(cues[index + 1]).get("time")).get("total", 0.0)) * 1000.0) if index + 1 < cues.size() else duration
		var text: = field(cue, "text")
		if text.strip_edges().is_empty():
			continue
		lines.append(LyricsParser.line(start, end if end > start else -1, text))
	return lines
