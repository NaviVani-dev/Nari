class_name NariPlugin extends Node

var id: = ""
var manifest: = {}
var _runtime: RefCounted
var _log: Log
var _settings: = Callable()
var _cleanup: Array[Callable] = []
var _videos: = {}
var _last_video: = 0

const IMAGES: = ["png", "jpg", "jpeg", "webp", "svg", "bmp", "tga"]
const SOUNDS: = {"mp3": "AudioStreamMP3", "ogg": "AudioStreamOggVorbis", "wav": "AudioStreamWAV"}

static func load_file(path: String) -> Resource:
	if path.is_empty():
		return null
	var extension: = path.get_extension().to_lower()
	if path.begins_with("res://"):
		return ResourceLoader.load(path)
	if extension in IMAGES:
		var image: = Image.load_from_file(path)
		return ImageTexture.create_from_image(image) if image else null
	if SOUNDS.has(extension):
		return ClassDB.class_call_static(SOUNDS[extension], "load_from_file", path)
	return ResourceLoader.load(path)

static func resolve(callable: Callable, args: Array) -> Variant:
	if not callable.is_valid():
		return null
	var request: = MusicProvider.Request.new()
	var value: Variant = callable.callv(args + [request.finish])
	if value != null or request.finished:
		return value if value != null else request.result
	(Engine.get_main_loop() as SceneTree).create_timer(HTTPService.TIMEOUT).timeout.connect(request.finish.bind(null))
	return await request.done

func start(main: String) -> String:
	_log = Log.new(str(manifest.get("name", id)))
	if not ClassDB.class_exists("LuaRuntime"):
		Plugins.report_error(id, "the native plugin runtime is unavailable")
		return "the native plugin runtime is unavailable"
	_runtime = ClassDB.instantiate("LuaRuntime")
	return _runtime.start(self, id, str(manifest["path"]), main, Package.permissions(manifest))

func _process(_delta: float) -> void :
	if _runtime:
		_runtime.pump()

func write_log(level: String, text: String) -> void :
	if level == "warn":
		_log.warn(text)
	else:
		_log.log(text)

func set_log_color(color: String) -> void :
	_log.color = Color.from_string(color, _log.color)

func emit_event(event: String, args: Array) -> void :
	if _runtime:
		_runtime.emit(event, args)

func _on_nari_ready() -> void :
	if _runtime:
		_runtime.emit("ready", [])

func teardown() -> void :
	if _runtime:
		_runtime.stop()
		_runtime = null
	_cleanup.reverse()
	for undo in _cleanup:
		undo.call()
	_cleanup.clear()

func is_theme() -> bool:
	return manifest.has("theme")

func theme_apply(overrides: Dictionary) -> void :
	Themes.script_apply(overrides)

func theme_color(name: String, value: Variant) -> void :
	Themes.script_color(name, value)

func theme_text(scope: String, style: Variant) -> void :
	Themes.script_text(scope, style)

func theme_settings(listed: Array) -> void :
	Themes.script_settings(listed)

func theme_setting(key: String) -> Variant:
	return Themes.setting_value(str(manifest["theme"]), key)

func theme_page() -> String:
	return Themes.current_page()

func theme_info() -> Dictionary:
	return {"id": str(manifest["theme"]), "path": str(manifest["path"]), "folder": ProjectSettings.globalize_path(str(manifest["path"]))}

func has_settings() -> bool:
	return _settings.is_valid()

func settings_entries() -> Array:
	var entries: Variant = _settings.call() if _settings.is_valid() else []
	if not entries is Array:
		return []
	for entry: Variant in entries:
		if entry is Dictionary:
			entry["icon"] = texture(entry.get("icon"))
	return entries

func texture(icon: Variant) -> Texture2D:
	if icon is Texture2D:
		return icon
	if icon is String and not (icon as String).is_empty():
		return load_file(path_of(icon)) as Texture2D
	return preload("res://assets/icons/more.svg")

func path_of(file: String) -> String:
	var path: = file if file.is_absolute_path() else str(manifest["path"]).path_join(file)
	return path if readable(path) else ""

func readable(path: String) -> bool:
	if path.begins_with("res://") or Plugins.ALL_ACCESS in Package.permissions(manifest):
		return true
	var target: = ProjectSettings.globalize_path(path).simplify_path()
	for root in [str(manifest["path"]), Plugins.DATA_DIR.path_join(id), "user://downloads".path_join(id)]:
		if target.begins_with(ProjectSettings.globalize_path(root).simplify_path() + "/"):
			return true
	return false

func load_relative(file: String) -> Resource:
	return load_file(path_of(file))

func add_home_entry(spec: Dictionary) -> void :
	spec["icon"] = texture(spec.get("icon"))
	spec["id"] = "%s.%s" % [id, spec.get("id", spec.get("title", ""))]
	var color: = str(spec.get("color", "Gray"))
	for part in ["bg", "gradient", "fg"]:
		spec[part] = ThemeEngine.Colors.get(color + part.capitalize(), ThemeEngine.Colors.get("Gray" + part.capitalize()))
	_extend(Plugins.home_entries, spec)

func add_now_playing_tab(spec: Dictionary) -> void :
	spec["icon"] = texture(spec.get("icon"))
	spec["id"] = "%s.%s" % [id, spec.get("id", "tab")]
	_extend(Plugins.now_playing_tabs, spec)

func add_settings_entry(category: String, builder: Callable) -> void :
	_extend(Plugins.settings_extras, {"category": category, "builder": func() -> Array:
		var entries: Variant = builder.call()
		if not entries is Array:
			return []
		for entry: Variant in entries:
			if entry is Dictionary:
				entry["icon"] = texture(entry.get("icon"))
				entry["section"] = str(entry.get("section", manifest.get("name", id)))
		return entries})

func _extend(registry: Array[Dictionary], entry: Dictionary) -> void :
	registry.append(entry)
	_cleanup.append(func(): registry.erase(entry))

func set_settings(builder: Callable) -> void :
	_settings = builder

func open_webview(spec: Dictionary) -> Control:
	if not ClassDB.class_exists("WebView") or not ClassDB.class_call_static("WebView", "is_available"):
		return null
	var options: = {"title": str(spec.get("title", "")), "service": str(spec.get("service", manifest.get("name", id))), "scripts": spec.get("scripts", [])}
	for key in WebScreen.OPTIONS:
		if spec.has(key):
			options[key] = spec[key]
	Main.change_page(Main.Pages.Web, options)
	var page: = Main.get_page() as WebScreen
	if not page:
		return null
	_cleanup.append(close_webview.bind(page.view))
	return page.view

func close_webview(view: Control) -> void:
	var page: = Main.get_page() as WebScreen
	if page and is_instance_valid(view) and page.view == view:
		Main.go_back()

func add_lyrics_provider(spec: Dictionary) -> void :
	var provider: = LuaLyrics.new(spec)
	MediaPlayer.lyrics.register(provider)
	_cleanup.append(MediaPlayer.lyrics.unregister.bind(provider))

func add_music_provider(spec: Dictionary) -> MusicProvider:
	spec["icon"] = texture(spec.get("icon"))
	var provider: = LuaMusic.new(spec, texture)
	MediaPlayer.register_provider(provider)
	_cleanup.append(MediaPlayer.unregister_provider.bind(provider))
	return provider

func add_visualizer(spec: Dictionary) -> void :
	var entry: = {"build": spec.get("build", Callable()), "update": spec.get("update", Callable()), "params": {}}
	if spec.has("shader"):
		entry["shader"] = load_relative(str(spec["shader"])) as Shader
	var params: Dictionary = spec.get("params", {})
	for key: Variant in params:
		var value: Variant = params[key]
		entry["params"][key] = load_relative(value) if value is String and (value as String).get_extension().to_lower() in IMAGES else value
	Visualizers.register(entry)
	_cleanup.append(Visualizers.unregister.bind(entry))

func add_cover_view(spec: Dictionary) -> String:
	var entry: = {
		"id": "%s.%s" % [id, spec.get("id", "view")],
		"icon": texture(spec.get("icon")),
		"title": str(spec.get("title", "")),
		"provider": str(spec.get("provider", "")),
		"available": false,
		"hide_unavailable": bool(spec.get("hide_unavailable", false)),
		"momentary": bool(spec.get("momentary", false)),
		"texture": null,
		"on_toggle": spec.get("on_toggle", Callable()),
	}
	_extend(Plugins.cover_views, entry)
	_cleanup.append(func():
		if Plugins.cover_view == entry["id"]:
			Plugins.set_cover_view(""))
	return entry["id"]

func cover_view_available(key: String, available: bool) -> void:
	if key.begins_with(id + "."):
		Plugins.update_cover_view(key, "available", available)

func cover_view_texture(key: String, view: Texture2D) -> void:
	if key.begins_with(id + "."):
		Plugins.update_cover_view(key, "texture", view)

func cover_view_active(key: String) -> bool:
	return Plugins.cover_view == key

func add_output(spec: Dictionary) -> String:
	var entry: = {
		"id": "%s.%s" % [id, spec.get("id", "output")],
		"scan": spec.get("scan", Callable()),
		"connect": spec.get("connect", Callable()),
		"disconnect": spec.get("disconnect", Callable()),
		"volume": spec.get("volume", Callable()),
	}
	_extend(Plugins.outputs, entry)
	_cleanup.append(Plugins.release_output.bind(entry["id"]))
	return entry["id"]

func release_output(key: String) -> void:
	if key.begins_with(id + "."):
		Plugins.release_output(key)

func output_connected(key: String) -> bool:
	return Plugins.output.get("key") == key and Plugins.is_output_connected()

func open_video(source: String, spec: Dictionary) -> int:
	var remote: = MotionPlayer.is_remote(source)
	if remote and not (Plugins.ALL_ACCESS in Package.permissions(manifest) or "network" in Package.permissions(manifest)):
		return -1
	var player: = MotionPlayer.create(source if remote else path_of(source))
	if player == null:
		return -1
	_last_video += 1
	var id: = _last_video
	player.looping = bool(spec.get("loop", false))
	player.playing = bool(spec.get("autoplay", true))
	if bool(spec.get("music", false)):
		player.sync = func() -> float: return MediaPlayer.get_position() / 1000.0
	var ready: Callable = spec.get("on_ready", Callable())
	var failed: Callable = spec.get("on_error", Callable())
	var ended: Callable = spec.get("on_end", Callable())
	player.settled.connect(func(error: String):
		if error.is_empty() and ready.is_valid():
			ready.call(player.texture)
		elif not error.is_empty() and failed.is_valid():
			failed.call(error))
	if ended.is_valid():
		player.ended.connect(ended)
	_videos[id] = player
	add_child(player)
	_cleanup.append(close_video.bind(id))
	return id

func video_texture(id: int) -> Texture2D:
	return _videos[id].texture if _videos.has(id) else null

func video_playing(id: int, playing: bool) -> void:
	if _videos.has(id):
		_videos[id].playing = playing

func video_seek(id: int, seconds: float) -> void:
	if _videos.has(id):
		_videos[id].seek(seconds)

func video_position(id: int) -> float:
	return _videos[id].position() if _videos.has(id) else 0.0

func video_length(id: int) -> float:
	return _videos[id].length() if _videos.has(id) else 0.0

func video_watch(id: int, viewer: CanvasItem) -> void:
	if _videos.has(id) and viewer:
		_videos[id].watch(viewer)

func close_video(id: int) -> void:
	if _videos.has(id):
		_videos[id].queue_free()
		_videos.erase(id)

func add_command(command_name: String, description: String, handler: Callable) -> bool:
	var run: = func(args: PackedStringArray) -> Variant: return handler.call(Array(args))
	if not DevTools.register_command(command_name, description, run, "", str(manifest.get("name", id))):
		return false
	_cleanup.append(DevTools.unregister_command.bind(command_name))
	return true

func add_discover_section(spec: Dictionary) -> void :
	spec["plugin"] = id
	spec["id"] = "%s.%s" % [id, spec.get("id", "section")]
	_extend(Plugins.discover_sections, spec)

func add_item_action(spec: Dictionary) -> void :
	spec["icon"] = texture(spec.get("icon")) if spec.has("icon") else null
	_extend(Plugins.item_actions, spec)

func add_effect(spec: Dictionary) -> void :
	var effect: = {
		"id": "%s.%s" % [id, spec.get("id", "effect")],
		"text": str(spec.get("name", spec.get("id", "Effect"))),
		"icon": texture(spec.get("icon")),
		"spec": {"chain": spec.get("chain", []), "pitch": spec.get("pitch", 1.0), "speed": spec.get("speed", 1.0)},
	}
	_extend(Plugins.effects, effect)
	_cleanup.append(func():
		if MediaPlayer.get_music_effect_state().get("custom", "") == effect["id"]:
			MediaPlayer.reset_music_effect())

class LuaLyrics extends LyricsProvider:
	var _search: Callable

	func _init(spec: Dictionary) -> void :
		super (str(spec.get("id", "")), str(spec.get("name", "")), int(spec.get("trust", 0)), Color(str(spec.get("color", "ffffff"))))
		online = bool(spec.get("online", true))
		agent = str(spec.get("agent", ""))
		_search = spec.get("search", Callable())

	func search(song: Dictionary) -> Array[Dictionary]:
		var found: Array[Dictionary] = []
		var value: Variant = await NariPlugin.resolve(_search, [self, song])
		if value is Array:
			for entry: Variant in value:
				if entry is Dictionary:
					found.append(entry)
		return found

class LuaMusic extends MusicProvider:
	var _spec: Dictionary
	var _texture: Callable

	func _init(spec: Dictionary, textures: Callable) -> void :
		super (str(spec.get("id", "")), str(spec.get("name", "")), str(spec.get("description", "")), spec.get("icon") as Texture2D, Color(str(spec.get("color", "ffffff"))))
		streams = bool(spec.get("streams", false))
		supports_likes = spec.has("get_liked") or spec.has("set_liked")
		supports_quality = spec.has("media_uri")
		auto_discover = bool(spec.get("auto_discover", true))
		paged = bool(spec.get("paged", false)) and spec.has("get_page")
		_spec = spec
		_texture = textures

	func _entries(value: Variant) -> Array:
		var entries: = _list(value)
		for entry: Variant in entries:
			if entry is Dictionary:
				entry["icon"] = _texture.call(entry.get("icon"))
		return entries

	func _sync(method: String, args: Array, fallback: Variant) -> Variant:
		var callable: Callable = _spec.get(method, Callable())
		var value: Variant = callable.callv([self] + args) if callable.is_valid() else null
		return fallback if value == null else value

	func _async(method: String, args: Array, fallback: Variant) -> Variant:
		var value: Variant = await NariPlugin.resolve(_spec.get(method, Callable()), [self] + args)
		return fallback if value == null else value

	static func _dict(value: Variant) -> Dictionary:
		return value if value is Dictionary else {}

	static func _list(value: Variant) -> Array:
		return value if value is Array else []

	func is_configured() -> bool:
		return bool(_sync("is_configured", [], true))

	func setup_entries() -> Array:
		return _entries(_sync("setup_entries", [], []))

	func settings_entries() -> Array:
		return _entries(_sync("settings_entries", [], setup_entries()))

	func is_loading() -> bool:
		return bool(_sync("is_loading", [], false))

	func is_ready() -> bool:
		return bool(_sync("is_ready", [], true))

	func get_status() -> Dictionary:
		return _dict(_sync("get_status", [], {}))

	func get_tracks() -> Array:
		return _list(await _async("get_tracks", [], []))

	func get_albums() -> Array:
		return _list(await _async("get_albums", [], []))

	func get_artists() -> Array:
		return _list(await _async("get_artists", [], []))

	func search(query: String, filters: Dictionary) -> Variant:
		return await _async("search", [query, filters], null)

	func get_hints(query: String) -> Variant:
		var hints: Variant = await _async("get_hints", [query], null)
		return hints if hints is Array else null

	func get_genres() -> Variant:
		return await _async("get_genres", [], null)

	func get_album(album_id: String) -> Dictionary:
		return _dict(await _async("get_album", [album_id], {}))

	func get_artist(artist_id: String) -> Dictionary:
		return _dict(await _async("get_artist", [artist_id], {}))

	func get_song(song_id: String) -> Dictionary:
		return _dict(await _async("get_song", [song_id], {}))

	func get_raw_lyrics(song_id: String) -> Dictionary:
		return _dict(await _async("get_raw_lyrics", [song_id], {}))

	func playable(tracks: Array) -> Array:
		return _list(await _async("playable", [tracks], []))

	func media_uri(track: Dictionary, quality: String) -> String:
		return str(_sync("media_uri", [track, quality], ""))

	func transcodes(_quality: String) -> bool:
		return false

	func get_cover_path(kind: String, cover_id: String, thumb: bool) -> String:
		return str(await _async("get_cover_path", [kind, cover_id, thumb], ""))

	func get_playlists() -> Array:
		return _list(await _async("get_playlists", [], []))

	func get_playlist(playlist_id: String) -> Dictionary:
		return _dict(await _async("get_playlist", [playlist_id], {}))

	func create_playlist(playlist_name: String) -> String:
		return str(await _async("create_playlist", [playlist_name], ""))

	func delete_playlist(playlist_id: String) -> void :
		await _async("delete_playlist", [playlist_id], null)

	func rename_playlist(playlist_id: String, playlist_name: String) -> void :
		await _async("rename_playlist", [playlist_id, playlist_name], null)

	func add_to_playlist(playlist_id: String, song_ids: PackedStringArray) -> void :
		await _async("add_to_playlist", [playlist_id, song_ids], null)

	func remove_from_playlist(playlist_id: String, song_id: String) -> void :
		await _async("remove_from_playlist", [playlist_id, song_id], null)

	func set_playlist_image(playlist_id: String, path: String) -> void :
		await _async("set_playlist_image", [playlist_id, path], null)

	func get_radio(kind: String, item_id: String) -> Variant:
		var tracks: Variant = await _async("get_radio", [kind, item_id], null)
		return tracks if tracks is Array else null

	func get_discover() -> Variant:
		var sections: Variant = await _async("get_discover", [], null)
		return sections if sections is Array else null

	func get_page(kind: String, context_id: String, offset: int, limit: int) -> Variant:
		var page: Variant = await _async("get_page", [kind, context_id, offset, limit], null)
		return page if page is Dictionary else null

	func get_liked(kind: String) -> Variant:
		var found: Variant = await _async("get_liked", [kind], null)
		return found if found is Array else null

	func set_liked(kind: String, id: String, liked: bool) -> void :
		await _async("set_liked", [kind, id, liked], null)
