class_name ConsoleCommands extends RefCounted

const LIST_LIMIT := 30
const SEARCH_LIMIT := 10
const PAGE_KEYS := {"album": "album_id", "artist": "artist_id", "playlist": "playlist_id", "settings": "category"}
const REPEAT_MODES := {"off": 0, "all": 1, "one": 2}

static func install(tools: Node) -> void:
	var add: Callable = tools.register_command
	add.call("help", "Lists every command, or explains one", func(args: PackedStringArray) -> Variant: return _help(tools, args), "help [command]")
	add.call("clear", "Empties the console", func(_args: PackedStringArray) -> Variant:
		tools.clear_output()
		return null)
	add.call("play", "Resumes, or plays a song by id or by the best search match", _play, "play [song id | words]")
	add.call("pause", "Pauses the music", func(_args: PackedStringArray) -> Variant:
		if MediaPlayer.is_playing():
			MediaPlayer.toggle()
		return "Paused")
	add.call("toggle", "Plays or pauses", func(_args: PackedStringArray) -> Variant:
		MediaPlayer.toggle()
		return "Paused" if MediaPlayer.is_playing() else "Playing")
	add.call("next", "Skips to the next song", func(_args: PackedStringArray) -> Variant:
		MediaPlayer.next()
		return null)
	add.call("prev", "Goes back to the previous song", func(_args: PackedStringArray) -> Variant:
		MediaPlayer.previous()
		return null)
	add.call("seek", "Jumps to a time, or moves by seconds", _seek, "seek <1:23 | 83 | +10 | -10>")
	add.call("now", "Shows the current song", _now)
	add.call("queue", "Lists the queue", _queue)
	add.call("search", "Searches songs, albums and artists", _search, "search <words>")
	add.call("shuffle", "Turns shuffle on or off", _shuffle, "shuffle [on | off]")
	add.call("repeat", "Sets the repeat mode", _repeat, "repeat [off | all | one]")
	add.call("effect", "Lists sound effects, or turns one on or off", _effect, "effect [name | off]")
	add.call("open", "Opens a screen", _open, "open <home | tracks | albums | artists | playlists | album <id> | artist <id> | playlist <id> | nowplaying | settings [category] | search | soundboard | about>")
	add.call("back", "Goes back one screen", func(_args: PackedStringArray) -> Variant:
		Main.go_back()
		return null)
	add.call("library", "Shows the music provider and how big the library is", _library)
	add.call("plugins", "Lists installed plugins", _plugins)
	add.call("plugin", "Turns a plugin on or off", _plugin, "plugin <on | off> <id>")
	add.call("reload", "Reloads every plugin, or the current screen", _reload, "reload [page]")
	add.call("errors", "Shows the latest plugin errors with their stack traces", _errors, "errors [count]")
	add.call("get", "Reads a setting", _get_setting, "get <section.key>")
	add.call("set", "Changes a setting", _set_setting, "set <section.key> <value>")
	add.call("stats", "Shows or hides the performance stats (F3)", func(_args: PackedStringArray) -> Variant:
		tools.stats.visible = not tools.stats.visible
		return null)
	add.call("motion", "Lists the animated backgrounds and covers that are playing", func(_args: PackedStringArray) -> Variant:
		var players := tools.get_tree().get_nodes_in_group(MotionPlayer.GROUP)
		return "Nothing is playing" if players.is_empty() else "\n".join(players.map(func(player: MotionPlayer): return player.describe())))
	add.call("restart", "Restarts Nari", func(_args: PackedStringArray) -> Variant:
		tools.restart()
		return null)

static func _help(tools: Node, args: PackedStringArray) -> Variant:
	var commands: Dictionary = tools.commands()
	if not args.is_empty():
		var wanted: Dictionary = commands.get(args[0], {})
		if wanted.is_empty():
			return "There is no command called '%s'" % args[0]
		return "%s\n  %s" % [wanted["usage"], wanted["description"]]
	var names := commands.keys()
	names.sort()
	var lines := []
	for name: String in names:
		var entry: Dictionary = commands[name]
		var owner := str(entry["owner"])
		lines.append("%-10s %s%s" % [name, entry["description"], "  (%s)" % owner if not owner.is_empty() else ""])
	lines.append("Anything else runs as a GDScript expression, like MediaPlayer.get_position() or Plugins.errors.size()")
	return lines

static func _describe(song: Dictionary) -> String:
	return "%s — %s  [%s]" % [song.get("title", "?"), song.get("artist", "?"), song.get("id", "")]

static func _play(args: PackedStringArray) -> Variant:
	if args.is_empty():
		MediaPlayer.play()
		return "Playing"
	var wanted := " ".join(args)
	var song: Dictionary = await MediaPlayer.get_song(wanted)
	if not song.is_empty():
		MediaPlayer.play(wanted)
		return "Playing " + _describe(song)
	var tracks: Array = (await MediaPlayer.search(wanted)).get("tracks", [])
	if tracks.is_empty():
		return "No song matches '%s'" % wanted
	MediaPlayer.play_tracks(tracks, str(tracks[0].get("id", "")))
	return "Playing %s (%s queued)" % [_describe(tracks[0]), MediaPlayer.format_song_count(tracks.size())]

static func _seek(args: PackedStringArray) -> Variant:
	if args.is_empty():
		return "Use seek 1:23, seek 83, seek +10 or seek -10"
	var text := args[0]
	var seconds := 0.0
	for part in text.trim_prefix("+").trim_prefix("-").split(":"):
		seconds = seconds * 60.0 + part.to_float()
	var target := int(seconds * 1000.0)
	if text.begins_with("+"):
		target = MediaPlayer.get_position() + target
	elif text.begins_with("-"):
		target = MediaPlayer.get_position() - target
	target = clampi(target, 0, maxi(MediaPlayer.get_duration(), 0))
	MediaPlayer.seek(target)
	return "At " + MediaPlayer.format_duration(target)

static func _now(_args: PackedStringArray) -> Variant:
	var song := MediaPlayer.get_current_song()
	if song.is_empty():
		return "Nothing is playing"
	var effect := MediaPlayer.get_music_effect_state()
	var effect_name := str(effect.get("custom", ""))
	if effect_name.is_empty():
		effect_name = MediaPlayer.effect_id(effect.get("effect", MediaPlayer.MusicEffect.NONE))
	return [
		"%s %s" % ["Playing" if MediaPlayer.is_playing() else "Paused", _describe(song)],
		"%s  ·  %s / %s" % [song.get("album", ""), MediaPlayer.format_duration(MediaPlayer.get_position()), MediaPlayer.format_duration(MediaPlayer.get_duration())],
		"Shuffle %s  ·  repeat %s  ·  effect %s" % ["on" if MediaPlayer.is_shuffled() else "off", REPEAT_MODES.find_key(MediaPlayer.get_repeat()), effect_name],
	]

static func _queue(_args: PackedStringArray) -> Variant:
	var queue: Array = await MediaPlayer.get_queue()
	if queue.is_empty():
		return "The queue is empty"
	var current := int(MediaPlayer.get_playback_state().get("index", -1))
	var lines := []
	var start := clampi(current - 2, 0, maxi(queue.size() - LIST_LIMIT, 0))
	for index in range(start, mini(start + LIST_LIMIT, queue.size())):
		lines.append("%s%3d. %s" % ["▶ " if index == current else "  ", index + 1, _describe(queue[index])])
	if queue.size() > LIST_LIMIT:
		lines.append("  … %s in total" % MediaPlayer.format_song_count(queue.size()))
	return lines

static func _search(args: PackedStringArray) -> Variant:
	if args.is_empty():
		return "Use search <words>"
	var found: Dictionary = await MediaPlayer.search(" ".join(args))
	var lines := []
	for kind: String in ["tracks", "albums", "artists"]:
		var items: Array = found.get(kind, [])
		lines.append("%s (%d)" % [kind.capitalize(), items.size()])
		for item: Dictionary in items.slice(0, SEARCH_LIMIT):
			match kind:
				"tracks": lines.append("  " + _describe(item))
				"albums": lines.append("  %s — %s  [%s]" % [item.get("title", "?"), item.get("artist", "?"), item.get("id", "")])
				"artists": lines.append("  %s  [%s]" % [item.get("name", "?"), item.get("id", "")])
	return lines

static func _shuffle(args: PackedStringArray) -> Variant:
	var on := not MediaPlayer.is_shuffled() if args.is_empty() else args[0] == "on"
	MediaPlayer.shuffle(on)
	return "Shuffle " + ("on" if on else "off")

static func _repeat(args: PackedStringArray) -> Variant:
	var mode := (MediaPlayer.get_repeat() + 1) % 3 if args.is_empty() else int(REPEAT_MODES.get(args[0], -1))
	if mode < 0:
		return "Use repeat off, repeat all or repeat one"
	MediaPlayer.repeat(mode)
	return "Repeat " + str(REPEAT_MODES.find_key(mode))

static func _reload(args: PackedStringArray) -> Variant:
	if not args.is_empty() and args[0] == "page":
		Main.reload_page()
		return "Reloaded the screen"
	Plugins.reload_all()
	return null

static func _effect(args: PackedStringArray) -> Variant:
	if args.is_empty():
		var names := []
		for effect in MediaPlayer.MusicEffect.values():
			if effect != MediaPlayer.MusicEffect.NONE:
				names.append(MediaPlayer.effect_id(effect))
		for effect: Dictionary in Plugins.effects:
			names.append(effect["id"])
		return "Effects: " + ", ".join(names)
	var wanted := args[0]
	if wanted == "off" or wanted == "none":
		MediaPlayer.reset_music_effect()
		return "Effect off"
	for effect in MediaPlayer.MusicEffect.values():
		if MediaPlayer.effect_id(effect) == wanted:
			MediaPlayer.apply_music_effect(effect)
			return "Effect " + wanted
	for effect: Dictionary in Plugins.effects:
		if effect["id"] == wanted:
			MediaPlayer.apply_custom_effect(wanted, effect["spec"])
			return "Effect " + wanted
	return "There is no effect called '%s'" % wanted

static func _open(args: PackedStringArray) -> Variant:
	if args.is_empty():
		return "Use open <screen> [id]"
	var name := args[0].to_lower()
	var page: Variant = null
	for key: String in Main.Pages.keys():
		if key.to_lower() == name:
			page = Main.Pages[key]
	if page == null:
		return "There is no screen called '%s'" % name
	var data := {}
	if PAGE_KEYS.has(name) and args.size() > 1:
		data[PAGE_KEYS[name]] = args[1]
	Main.change_page(page, data)
	return "Opened " + name

static func _library(_args: PackedStringArray) -> Variant:
	var provider := MediaPlayer.provider
	return "%s: %d songs, %d albums, %d artists%s" % [
		provider.display_name if provider else "No provider",
		(await MediaPlayer.get_tracks()).size(),
		(await MediaPlayer.get_albums()).size(),
		(await MediaPlayer.get_artists()).size(),
		" (loading)" if MediaPlayer.is_library_loading() else "",
	]

static func _plugins(_args: PackedStringArray) -> Variant:
	if Plugins.manifests.is_empty():
		return "No plugins installed"
	var lines := []
	for id: String in Plugins.manifests:
		var state := "off"
		if Plugins.is_enabled(id):
			state = "on"
		elif Plugins.is_halted(id):
			state = "stopped"
		var failures := Plugins.errors.filter(func(entry: Dictionary) -> bool: return entry["id"] == id).size()
		lines.append("%-8s %s  [%s]%s" % [state, Plugins.manifests[id].get("name", id), id, "  %d errors" % failures if failures > 0 else ""])
	return lines

static func _plugin(args: PackedStringArray) -> Variant:
	if args.size() < 2 or not args[0] in ["on", "off"]:
		return "Use plugin on <id> or plugin off <id>"
	if not Plugins.manifests.has(args[1]):
		return "There is no plugin called '%s'" % args[1]
	SettingsManager.plugins.set_enabled(args[1], args[0] == "on")
	return "%s is %s" % [args[1], "on" if Plugins.is_enabled(args[1]) else "off"]

static func _errors(args: PackedStringArray) -> Variant:
	if Plugins.errors.is_empty():
		return "No plugin errors"
	var count := int(args[0]) if not args.is_empty() else 5
	var lines := []
	for entry: Dictionary in Plugins.errors.slice(-maxi(count, 1)):
		var place := " (%s:%d)" % [entry["file"], entry["line"]] if not str(entry["file"]).is_empty() else ""
		lines.append("%s  %s%s: %s%s" % [entry["time"], entry["name"], " [stopped]" if entry["fatal"] else "", entry["message"], place])
		for line in str(entry["trace"]).split("\n", false):
			lines.append("    " + line)
	return lines

static func _setting_parts(path: String) -> PackedStringArray:
	var parts := path.split(".", false, 1)
	return parts if parts.size() == 2 else PackedStringArray()

static func _get_setting(args: PackedStringArray) -> Variant:
	var parts := _setting_parts(args[0] if not args.is_empty() else "")
	if parts.is_empty():
		return "Use get <section.key>, like get general.developer_mode"
	var section: Variant = SettingsManager.get(parts[0])
	var value: Variant = section.get(parts[1]) if section is Object and parts[1] in section else SettingsManager.get_value(parts[0], parts[1])
	if SettingsManager.is_private(parts[0], parts[1]):
		return "%s = %s (private)" % [args[0], SettingsManager.HIDDEN]
	return "%s = %s" % [args[0], var_to_str(value)]

static func _set_setting(args: PackedStringArray) -> Variant:
	var parts := _setting_parts(args[0] if not args.is_empty() else "")
	if parts.is_empty() or args.size() < 2:
		return "Use set <section.key> <value>, like set general.developer_mode false"
	var text := " ".join(args.slice(1))
	var value: Variant = str_to_var(text)
	if value == null and text != "null":
		value = text
	var section: Variant = SettingsManager.get(parts[0])
	if section is Object and parts[1] in section:
		section.set(parts[1], value)
	else:
		SettingsManager.set_value(parts[0], parts[1], value)
	return null
