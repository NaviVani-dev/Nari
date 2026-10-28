extends Node

signal changed(section: String, key: String, value: Variant)

const SAVE_PATH: = "user://settings.cfg"
const PRIVATE_PATH: = "user://private.cfg"
const HIDDEN: = "••••"

class Section extends RefCounted:
	var _section: String

	func _init(section: String) -> void :
		_section = section

	func _store(key: String, value: Variant) -> void :
		SettingsManager.set_value(_section, key, value)

	func _fetch(key: String, fallback: Variant) -> Variant:
		return SettingsManager.get_value(_section, key, fallback)


	func reload() -> void :
		pass

	func reset(key: String) -> void :
		set(key, (get_script() as GDScript).new().get(key))

class LyricsSection extends Section:
	const DEFAULT_PROVIDERS: = ["local", "binimum", "musixmatch", "lrclib", "amll", "lyricsplus"]

	var providers: = PackedStringArray(DEFAULT_PROVIDERS):
		set(value):
			providers = value
			_store("providers", value)
	var show_romaji: = false:
		set(value):
			show_romaji = value
			_store("show_romaji", value)

	func _init() -> void :
		super ("lyrics")

	func reload() -> void :
		var offline: = not bool(_fetch("fetch_online", true))
		providers = PackedStringArray(_fetch("providers", PackedStringArray(["local"]) if offline else providers))
		show_romaji = _fetch("show_romaji", show_romaji)

	func set_provider(id: String, enabled: bool) -> void :
		var changed: = PackedStringArray()
		for entry in providers:
			if entry != id:
				changed.append(entry)
		if enabled:
			changed.append(id)
		providers = changed

class PluginsSection extends Section:
	var enabled: = PackedStringArray():
		set(value):
			enabled = value
			_store("enabled", value)
	var auto_update: = false:
		set(value):
			auto_update = value
			_store("auto_update", value)
	var approved: = PackedStringArray():
		set(value):
			approved = value
			_store("approved", value)

	func _init() -> void :
		super ("plugins")

	func reload() -> void :
		enabled = PackedStringArray(_fetch("enabled", enabled))
		auto_update = _fetch("auto_update", auto_update)
		approved = PackedStringArray(_fetch("approved", approved))

	func set_approved(id: String, allowed: bool) -> void :
		var changed: = PackedStringArray()
		for entry in approved:
			if entry != id:
				changed.append(entry)
		if allowed:
			changed.append(id)
		approved = changed

	func set_enabled(id: String, on: bool) -> void :
		var changed: = PackedStringArray()
		for entry in enabled:
			if entry != id:
				changed.append(entry)
		if on:
			changed.append(id)
		enabled = changed

class LibrarySection extends Section:
	var provider: = "local":
		set(value):
			provider = value
			_store("provider", value)
	var artist_info: = true:
		set(value):
			artist_info = value
			_store("artist_info", value)

	func _init() -> void :
		super ("library")

	func reload() -> void :
		provider = _fetch("provider", provider)
		artist_info = _fetch("artist_info", artist_info)

class GeneralSection extends Section:
	var dual_screen: = false:
		set(value):
			dual_screen = value
			_store("dual_screen", value)
	var swap_screens: = false:
		set(value):
			swap_screens = value
			_store("swap_screens", value)
	var bottom_window: = "":
		set(value):
			bottom_window = value
			_store("bottom_window", value)
	var boot_intro: = false:
		set(value):
			boot_intro = value
			_store("boot_intro", value)
	var close_to_tray: = true:
		set(value):
			close_to_tray = value
			_store("close_to_tray", value)
	var startup_page: = "Home":
		set(value):
			startup_page = value
			_store("startup_page", value)
	var offline_mode: = false:
		set(value):
			offline_mode = value
			_store("offline_mode", value)
	var developer_mode: = false:
		set(value):
			developer_mode = value
			_store("developer_mode", value)
	var avoid_notch: = false:
		set(value):
			avoid_notch = value
			_store("avoid_notch", value)
	var avoid_system_bars: = true:
		set(value):
			avoid_system_bars = value
			_store("avoid_system_bars", value)
	var swap_face_glyphs: = false:
		set(value):
			swap_face_glyphs = value
			_store("swap_face_glyphs", value)
	var nintendo_layout: = false:
		set(value):
			nintendo_layout = value
			_store("nintendo_layout", value)
	var haptics: = true:
		set(value):
			haptics = value
			_store("haptics", value)
	var clock_format: = "24h":
		set(value):
			clock_format = value
			_store("clock_format", value)
	var window_mode: = "windowed":
		set(value):
			window_mode = value
			_store("window_mode", value)
	var resolution: = "":
		set(value):
			resolution = value
			_store("resolution", value)
	var window_borders: = true:
		set(value):
			window_borders = value
			_store("window_borders", value)
	var window_controls: = false:
		set(value):
			window_controls = value
			_store("window_controls", value)
	var window_controls_left: = OS.get_name() == "macOS":
		set(value):
			window_controls_left = value
			_store("window_controls_left", value)
	var notify_updates: = true:
		set(value):
			notify_updates = value
			_store("notify_updates", value)
	var skipped_update: = "":
		set(value):
			skipped_update = value
			_store("skipped_update", value)

	func _init() -> void :
		super ("general")

	func reload() -> void :
		dual_screen = _fetch("dual_screen", dual_screen)
		swap_screens = _fetch("swap_screens", swap_screens)
		bottom_window = _fetch("bottom_window", bottom_window)
		boot_intro = _fetch("boot_intro", SettingsManager.get_value("theme", "boot_intro", boot_intro))
		close_to_tray = _fetch("close_to_tray", close_to_tray)
		startup_page = _fetch("startup_page", startup_page)
		offline_mode = _fetch("offline_mode", offline_mode)
		developer_mode = _fetch("developer_mode", developer_mode)
		avoid_notch = _fetch("avoid_notch", avoid_notch)
		avoid_system_bars = _fetch("avoid_system_bars", avoid_system_bars)
		swap_face_glyphs = _fetch("swap_face_glyphs", swap_face_glyphs)
		nintendo_layout = _fetch("nintendo_layout", nintendo_layout)
		haptics = _fetch("haptics", haptics)
		clock_format = _fetch("clock_format", clock_format)
		window_mode = _fetch("window_mode", window_mode)
		resolution = _fetch("resolution", resolution)
		window_borders = _fetch("window_borders", window_borders)
		window_controls = _fetch("window_controls", window_controls)
		window_controls_left = _fetch("window_controls_left", window_controls_left)
		notify_updates = _fetch("notify_updates", notify_updates)
		skipped_update = _fetch("skipped_update", skipped_update)

class ThemeSection extends Section:
	var adapt_to_song: = false:
		set(value):
			adapt_to_song = value
			_store("adapt_to_song", value)
	var ui_scale: = 1.0:
		set(value):
			ui_scale = value
			_store("ui_scale", value)
	var reduce_motion: = "system":
		set(value):
			reduce_motion = value
			_store("reduce_motion", value)
	var now_playing_controls: = "auto":
		set(value):
			now_playing_controls = value
			_store("now_playing_controls", value)
	var active: = "":
		set(value):
			active = value
			_store("active", value)
	var pill: = "comfy":
		set(value):
			pill = value
			_store("pill", value)
	var home_view: = "circle":
		set(value):
			home_view = value
			_store("home_view", value)
	var hidden_home: = PackedStringArray(["Folders"]):
		set(value):
			hidden_home = value
			_store("hidden_home", value)

	func _init() -> void :
		super ("theme")

	func reload() -> void :
		adapt_to_song = _fetch("adapt_to_song", adapt_to_song)
		ui_scale = _fetch("ui_scale", ui_scale)
		reduce_motion = _fetch("reduce_motion", reduce_motion)
		now_playing_controls = _fetch("now_playing_controls", now_playing_controls)
		active = _fetch("active", active)
		pill = _fetch("pill", pill)
		home_view = _fetch("home_view", home_view)
		hidden_home = PackedStringArray(_fetch("hidden_home", hidden_home))

class PlaybackSection extends Section:
	var normalize_volume: = false:
		set(value):
			normalize_volume = value
			_store("normalize_volume", value)
	var gapless: = true:
		set(value):
			gapless = value
			_store("gapless", value)
	var keep_screen_on: = true:
		set(value):
			keep_screen_on = value
			_store("keep_screen_on", value)
	var stream_quality: = "original":
		set(value):
			stream_quality = value
			_store("stream_quality", value)
	var download_quality: = "original":
		set(value):
			download_quality = value
			_store("download_quality", value)
	var soundfont: = "":
		set(value):
			soundfont = value
			_store("soundfont", value)
	var volume: = 1.0:
		set(value):
			volume = value
			_store("volume", value)
	var module_ending: = true:
		set(value):
			module_ending = value
			_store("module_ending", value)

	func _init() -> void :
		super ("playback")

	func reload() -> void :
		normalize_volume = _fetch("normalize_volume", normalize_volume)
		gapless = _fetch("gapless", gapless)
		keep_screen_on = _fetch("keep_screen_on", keep_screen_on)
		stream_quality = _fetch("stream_quality", stream_quality)
		download_quality = _fetch("download_quality", download_quality)
		soundfont = _fetch("soundfont", soundfont)
		volume = _fetch("volume", volume)
		module_ending = _fetch("module_ending", module_ending)

class PerformanceSection extends Section:
	var max_fps: = 60:
		set(value):
			max_fps = value
			_store("max_fps", value)
	var background: = "full":
		set(value):
			background = value
			_store("background", value)
	var background_quality: = "high":
		set(value):
			background_quality = value
			_store("background_quality", value)
	var battery_saving: = "medium":
		set(value):
			battery_saving = value
			_store("battery_saving", value)
	var video_decoding: = "auto":
		set(value):
			video_decoding = value
			_store("video_decoding", value)

	func _init() -> void :
		super ("performance")

	func reload() -> void :
		max_fps = _fetch("max_fps", max_fps)
		background = _fetch("background", background)
		background_quality = _fetch("background_quality", background_quality)
		battery_saving = _fetch("battery_saving", battery_saving)
		video_decoding = _fetch("video_decoding", video_decoding)

class DiscordSection extends Section:
	var enabled: = false:
		set(value):
			enabled = value
			_store("enabled", value)
	var status_name: = "nari":
		set(value):
			status_name = value
			_store("status_name", value)
	var show_paused: = false:
		set(value):
			show_paused = value
			_store("show_paused", value)
	var song_button: = true:
		set(value):
			song_button = value
			_store("song_button", value)
	var nari_button: = true:
		set(value):
			nari_button = value
			_store("nari_button", value)
	var fetch_artwork: = true:
		set(value):
			fetch_artwork = value
			_store("fetch_artwork", value)

	func _init() -> void :
		super ("discord")

	func reload() -> void :
		enabled = _fetch("enabled", enabled)
		status_name = _fetch("status_name", status_name)
		show_paused = _fetch("show_paused", show_paused)
		song_button = _fetch("song_button", song_button)
		nari_button = _fetch("nari_button", nari_button)
		fetch_artwork = _fetch("fetch_artwork", fetch_artwork)

var general: = GeneralSection.new()
var library: = LibrarySection.new()
var lyrics: = LyricsSection.new()
var theme: = ThemeSection.new()
var playback: = PlaybackSection.new()
var performance: = PerformanceSection.new()
var plugins: = PluginsSection.new()
var discord: = DiscordSection.new()

var _config: = ConfigFile.new()
var _private: = ConfigFile.new()
var _private_keys: = {}
var _loading: = false
var _save_queued: = false
var _private_dirty: = false
var _l: = Log.new("Settings", Color("5e97f2"))

func _ready() -> void :
	reload()

func mark_private(section: String, key: String) -> void :
	_private_keys[section + "/" + key] = true
	if not _config.has_section_key(section, key):
		return
	_private.set_value(section, key, _config.get_value(section, key))
	_config.erase_section_key(section, key)
	_private_dirty = true
	save()

func is_private(section: String, key: String) -> bool:
	return _private_keys.has(section + "/" + key)

func get_value(section: String, key: String, fallback: Variant = null) -> Variant:
	return (_private if is_private(section, key) else _config).get_value(section, key, fallback)

func set_value(section: String, key: String, value: Variant) -> void :
	var target: = _private if is_private(section, key) else _config
	if target.has_section_key(section, key) and target.get_value(section, key) == value:
		return
	target.set_value(section, key, value)
	if target == _private:
		_private_dirty = true
	if _loading:
		return
	_l.log("%s.%s is now '%s'" % [section, key, HIDDEN if target == _private else str(value)])
	changed.emit(section, key, value)
	_queue_save()

func _queue_save() -> void :
	if _save_queued:
		return
	_save_queued = true
	save.call_deferred()

func save() -> void :
	_save_queued = false
	if not FileUtil.write_text(SAVE_PATH, _config.encode_to_text()):
		_l.error("The settings file could not be written")
	if not _private_dirty or _private.get_sections().is_empty():
		return
	if Vault.save_config(_private, PRIVATE_PATH):
		_private_dirty = false
	else:
		_l.error("The private settings could not be written")

func _notification(what: int) -> void :
	if what in [NOTIFICATION_WM_CLOSE_REQUEST, NOTIFICATION_APPLICATION_PAUSED, NOTIFICATION_EXIT_TREE] and _save_queued:
		save()

func reload() -> void :
	_private = Vault.load_config(PRIVATE_PATH)
	var error: = _config.load(SAVE_PATH)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		_l.error("The settings file is unreadable, going back to the default settings (error %d)" % error)
		_config.clear()
	_loading = true
	for property in get_property_list():
		var value = get(property.name)
		if value is Section:
			value.reload()
	_loading = false
	save()
	_l.log("Loaded %d sections from '%s'" % [_config.get_sections().size(), SAVE_PATH])
