class_name SettingsScreen extends Page

const CAPTION_FADE := 0.135
const FLOAT_HEIGHT := 28.0
const FLOAT_TIME := 1.4
const GLYPH_MAX := 400.0
const CAPTION_SHARE := 0.68
const CAPTION_GAP := 0.02
const STARTUP_PAGES := {"Home": "Home", "Discover": "Discover", "Tracks": "Tracks", "Albums": "Albums", "Artists": "Artists", "Playlists": "Playlists", "Search": "Search", "Soundboard": "Soundboard"}
const UI_SCALE_RANGE := Vector3(0.5, 3.0, 0.25)
const PLUGIN_ICON := preload("res://assets/icons/plugin.svg")
const INTEGRATIONS_ICON := preload("res://assets/icons/integrations.svg")
const DISCORD_BUTTONS := {"song_button": "Song button", "nari_button": "Nari button"}
const DISCORD_BUTTON_ICONS := {"song_button": preload("res://assets/icons/music_note.svg"), "nari_button": preload("res://assets/icons/nari.svg")}
const SCROBBLE_ICONS := {"lastfm": preload("res://assets/icons/lastfm.svg"), "listenbrainz": preload("res://assets/icons/listenbrainz.svg")}
const DISCORD_NAMES := {"nari": "Nari", "provider": "Provider", "music": "Music", "title": "Title", "artist": "Artist", "artist_title": "Artist - Title"}
const WINDOW_MODES := {"windowed": "Windowed", "fullscreen": "Fullscreen", "exclusive": "Exclusive fullscreen"}
const RESOLUTIONS := ["1280x720", "1366x768", "1600x900", "1920x1080", "2560x1440", "3840x2160"]
const SECTION := preload("res://ui/shared/SettingSection.tscn")
const ADDON_PAGES := ["plugins", "themes"]

@onready var list: StairScroll = %List
@onready var showcase: Control = %Showcase
@onready var glyph: Icon = %Glyph
@onready var picture: Cover = %Picture
@onready var caption_title: NariLabel = %Title
@onready var caption_description: NariLabel = %Description

var _category := ""
var _entries: Array = []
var _selected := -1
var _caption_fade: Tween
var _glyph_rest := 0.0

func _ready() -> void:
	_category = str(data.get("category", ""))
	if not bottom:
		list.max_width = 0.0 if _category in ADDON_PAGES else UI.LIST_MAX_WIDTH
		caption_description.marquee = true
		if _category in ADDON_PAGES:
			showcase.hide()
		else:
			UI.place_detail(top, list, showcase, true)
	list.item_focused.connect(func(index: int, _item: Control): _select(index))
	caption_title.marquee = true
	var caption: Control = caption_title.get_parent()
	showcase.resized.connect(_fit_showcase)
	caption.minimum_size_changed.connect(_fit_showcase)
	_fit_showcase()
	var bob := func(offset: float):
		glyph.offset_top = -_glyph_rest + offset
		glyph.offset_bottom = _glyph_rest + offset
	if not Main.reduce_motion:
		var floating := create_tween().set_loops().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		floating.tween_method(bob, -FLOAT_HEIGHT, FLOAT_HEIGHT, FLOAT_TIME)
		floating.tween_method(bob, FLOAT_HEIGHT, -FLOAT_HEIGHT, FLOAT_TIME)
	if _category == "library":
		MediaPlayer.library_changed.connect(_load)
		MediaPlayer.library_ready.connect(_load.unbind(2))
		MediaPlayer.music_provider_changed.connect(_load)
	if _category == "integrations" and Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").connect("scrobble_account_changed", _on_scrobble_account_changed)
	if _category == "general":
		SettingsManager.changed.connect(func(section: String, key: String, _value: Variant):
			if section == "general" and key in ["developer_mode", "window_mode", "window_controls"]:
				_load())
	if _category == "plugins" or _category == "plugin":
		Plugins.plugins_changed.connect(_load)
		Plugins.install_finished.connect(_on_install_finished.bind("Plugin"))
	if _category == "themes":
		Themes.themes_changed.connect(_load)
		Themes.install_finished.connect(_on_install_finished.bind("Theme"))
	if _category == "appearance":
		Themes.themes_changed.connect(_load)
	if _category in ADDON_PAGES:
		Marketplace.index_changed.connect(_load)
		Marketplace.refresh()
	_load()

func _fit_showcase() -> void:
	var caption: Control = caption_title.get_parent()
	var height := maxf(showcase.size.y, 1.0)
	var share := clampf((height - caption.get_combined_minimum_size().y) / height, 0.0, CAPTION_SHARE)
	caption.anchor_top = share
	caption.anchor_bottom = share
	var area: Control = glyph.get_parent()
	area.anchor_bottom = maxf(share - CAPTION_GAP, area.anchor_top)
	var room := minf(area.size.x, (area.anchor_bottom - area.anchor_top) * height)
	_glyph_rest = clampf(room, 0.0, GLYPH_MAX) * 0.5
	glyph.offset_left = -_glyph_rest
	glyph.offset_right = _glyph_rest
	glyph.offset_top = -_glyph_rest
	glyph.offset_bottom = _glyph_rest

func _load() -> void:
	var fresh := sectioned(_entries_of(_category) + (Plugins.settings_entries(_category) if not _category.is_empty() else []))
	if _same_shape(fresh):
		_update_in_place(fresh)
		return
	var previous: int = list.get_selected()
	_entries = fresh
	list.container.headers = headers_of(_entries)
	list.shape_of = func(entry: Dictionary): return entry.has("slider")
	list.set_items(_entries, _create_item)
	_selected = -1
	var start := first_item(_entries, previous if previous >= 0 else focus_index)
	_select(start)
	list.focus_item(start)

func _same_shape(fresh: Array) -> bool:
	return not _entries.is_empty() and fresh.map(_shape_of) == _entries.map(_shape_of)

static func _shape_of(entry: Dictionary) -> String:
	if entry.has("header"):
		return "header:" + str(entry["header"])
	return "%s:%s" % [entry.get("plugin", ""), entry.get("title", "")]

func _update_in_place(fresh: Array) -> void:
	for index in fresh.size():
		var entry: Dictionary = _entries[index]
		entry.clear()
		entry.merge(fresh[index])
	for child in list.items.get_children():
		var item = child.get_meta(VirtualContainer.ITEM_META, child)
		if item is SettingItem or item is PluginItem:
			item.refresh()
	if _selected >= 0:
		_write_caption()

static func sectioned(entries: Array) -> Array:
	var sections := {}
	for entry: Dictionary in entries:
		var section := str(entry.get("section", ""))
		if not sections.has(section):
			sections[section] = [] if section.is_empty() else [{"header": section}]
		sections[section].append(entry)
	var grouped: Array = sections.get("", [])
	for section: String in sections:
		if not section.is_empty():
			grouped.append_array(sections[section])
	return grouped

static func headers_of(entries: Array) -> PackedInt32Array:
	var headers := PackedInt32Array()
	for index in entries.size():
		if entries[index].has("header"):
			headers.append(index)
	return headers

static func first_item(entries: Array, start: int) -> int:
	var index := clampi(start, 0, entries.size() - 1)
	while index + 1 < entries.size() and entries[index].has("header"):
		index += 1
	return index

static func create_entry(entry: Dictionary, changed: Callable) -> Control:
	if entry.has("header"):
		var header: Control = SECTION.instantiate()
		header.get_node("%Title").text = entry["header"]
		return header
	if entry.has("plugin"):
		return PluginItem.create(entry)
	return SettingItem.create(entry, changed)

func _create_item(entry: Dictionary) -> Control:
	return create_entry(entry, SettingItem.refresh_list.bind(list))

func _entries_of(category: String) -> Array:
	match category:
		"playback":
			var playback: Array = _section("Playback", [
				SettingItem.toggle("Normalize volume", "Plays every song at a similar loudness", preload("res://assets/icons/sound.svg"), "playback", "normalize_volume"),
				SettingItem.toggle("Gapless playback", "Runs tracks without pauses", preload("res://assets/icons/gapless.svg"), "playback", "gapless"),
				SettingItem.toggle("Keep screen on", "Keeps your device from going into sleep mode while Nari is focused and playing music", preload("res://assets/icons/charge.svg"), "playback", "keep_screen_on"),
			]) + _section("MIDI and modules", [
				{
					"title": "SoundFont",
					"description": "The instruments used to play MIDI files (.sf2)",
					"icon": preload("res://assets/icons/music_note.svg"),
					"value": func(): return SettingsManager.playback.soundfont.get_file().get_basename() if not SettingsManager.playback.soundfont.is_empty() else "None",
					"action": func(): SoundFontDialog.open(SettingItem.refresh_list.bind(list)),
					"reset": func(): SettingsManager.playback.reset("soundfont"),
				},
				SettingItem.toggle("Ending on module tracks", "Fades out looping module tracks (MOD, XM, IT, S3M...) instead of repeating them forever", preload("res://assets/icons/repeat.svg"), "playback", "module_ending"),
			])
			if MediaPlayer.can_download() and MediaPlayer.provider.supports_quality:
				playback.append_array(_section("Quality", [
					_choice("Stream quality", "How songs from your server are streamed", preload("res://assets/icons/headphones.svg"), "playback", "stream_quality",
						MusicProvider.QUALITIES.keys(), MusicProvider.QUALITIES),
					_choice("Download quality", "How songs are saved when you download them", preload("res://assets/icons/download.svg"), "playback", "download_quality",
						MusicProvider.QUALITIES.keys(), MusicProvider.QUALITIES),
				]))
			return playback
		"general":
			var screens: Array = [dual_screen_entry()]
			if Main.dual and not OS.has_feature("pc"):
				screens.append(_choice("Select main screen", "Choose which screen shows the top of the app", preload("res://assets/icons/repeat.svg"), "general", "swap_screens",
					[false, true], {false: "Top", true: "Bottom"}))
			if not OS.has_feature("pc"):
				screens.append(SettingItem.toggle("Avoid the notch", "Keeps the app clear of the camera cutout", preload("res://assets/icons/home.svg"), "general", "avoid_notch"))
				screens.append(SettingItem.toggle("Avoid Android elements", "Keeps the app clear of the space Android reserves for system bars", preload("res://assets/icons/home.svg"), "general", "avoid_system_bars"))
			if OS.has_feature("pc"):
				screens.append(_choice("Window mode", "How the app window fills your screen", preload("res://assets/icons/home.svg"), "general", "window_mode",
					WINDOW_MODES.keys(), WINDOW_MODES))
				if SettingsManager.general.window_mode == "exclusive":
					screens.append(_resolution_choice())
				if SettingsManager.general.window_mode == "windowed":
					screens.append(SettingItem.toggle("Window borders", "Shows the borders and title bar of your system around the window", preload("res://assets/icons/window_restore.svg"), "general", "window_borders"))
				screens.append(SettingItem.toggle("Show window controls", "Adds minimize, maximize and close buttons next to the clock", preload("res://assets/icons/window_maximize.svg"), "general", "window_controls"))
				if SettingsManager.general.window_controls:
					screens.append(_choice("Window controls side", "Where the window controls go in the top bar", preload("res://assets/icons/window_minimize.svg"), "general", "window_controls_left",
						[false, true], {false: "Right", true: "Left"}))
				screens.append(SettingItem.toggle("Close to tray", "Closing the window keeps the music going in the system tray", preload("res://assets/icons/music_note.svg"), "general", "close_to_tray"))
			var general: Array = _section("Window" if OS.has_feature("pc") else "Screens", screens) + _section("Startup", [
				_choice("Show on startup", "The screen that opens at launch", preload("res://assets/icons/home.svg"), "general", "startup_page",
					STARTUP_PAGES.keys(), STARTUP_PAGES),
				SettingItem.toggle("Intro on boot", "Shows the app name animation while your music loads", preload("res://assets/icons/play.svg"), "general", "boot_intro"),
			])
			if MediaPlayer.can_download():
				general.append_array(_section("Library", [SettingItem.toggle("Offline mode", "Only shows the songs you downloaded", preload("res://assets/icons/offline_mode.svg"), "general", "offline_mode")]))
			general.append_array(_section("Interface", [
				SettingItem.toggle("Nintendo button layout", "B confirms and A goes back, and X and Y trade places too", preload("res://assets/glyphs/XboxSeries/xbox_button_b.svg"), "general", "nintendo_layout"),
				SettingItem.toggle("Swap button glyphs", "Shows A/B and X/Y swapped, for controllers with a Nintendo layout", preload("res://assets/glyphs/XboxSeries/xbox_button_a.svg"), "general", "swap_face_glyphs"),
				SettingItem.toggle("Haptics", "Vibrates your controller or phone as you move around the app", preload("res://assets/icons/motion.svg"), "general", "haptics"),
				_choice("Clock format", "How the time is shown in the top bar", preload("res://assets/icons/time.svg"), "general", "clock_format",
					["24h", "12h"], {"24h": "24 hours", "12h": "12 hours"}),
			]))
			if AppUpdates.supported():
				general.append_array(_section("Updates", [SettingItem.toggle("Notify app updates", "Lets you know when a new version of Nari is out", preload("res://assets/icons/download.svg"), "general", "notify_updates")]))
			var developer: Array = [SettingItem.toggle("Developer mode", "F12 console, F5 reloads plugins, F6 reloads the screen, F3 shows performance stats, Alt+R restarts Nari", preload("res://assets/icons/integrations.svg"), "general", "developer_mode")]
			if SettingsManager.general.developer_mode:
				developer.append({"title": "Open console", "description": "Every log of the app, plugin errors included (F12)", "icon": preload("res://assets/icons/info.svg"), "action": DevTools.toggle_console})
				developer.append({"title": "Reload plugins", "description": "Restarts every plugin, even the ones that failed (F5)", "icon": preload("res://assets/icons/repeat.svg"), "action": DevTools.reload_plugins})
				developer.append({"title": "Restart Nari", "description": "Closes and opens the app again (Alt+R)", "icon": preload("res://assets/icons/play.svg"), "action": DevTools.restart})
			return general + _section("Developer", developer)
		"appearance":
			return _section("Theme", [{
				"title": "Themes",
				"description": "Colors, icons and backgrounds made by others",
				"icon": preload("res://assets/icons/background.svg"),
				"value": func(): return str(Themes.active.get("name", "Default")),
				"action": Main.change_page.bind(Main.Pages.Settings, {"category": "themes"}),
			}, _adapt_entry(),
				_choice("Background", "Select how much details does the background shows", preload("res://assets/icons/background.svg"), "performance", "background",
					["full", "gradient", "simple"], {"full": "Animated", "gradient": "Gradient only", "simple": "Simple"}),
			]) + _section("Layout", [
				_slider("UI scale", "How big the interface is drawn", preload("res://assets/icons/search.svg"), "theme", "ui_scale",
					UI_SCALE_RANGE, func(scale: float): return "%sx" % _number(scale)),
				_choice("Home appearance", "The carousel on the home screen", preload("res://assets/icons/home.svg"), "theme", "home_view",
					HomeView.NAMES.keys(), HomeView.NAMES),
				home_entries_entry(SettingItem.refresh_list.bind(list)),
				_choice("Now Playing pill", "The player shown at the bottom of every screen", preload("res://assets/icons/music_note.svg"), "theme", "pill",
					["comfy", "compact", "slim"], {"comfy": "Comfy", "compact": "Compact", "slim": "Slim"}),
				_choice("Show media controls on Now Playing", "Hides the controls after a few seconds without input", preload("res://assets/icons/play.svg"), "theme", "now_playing_controls",
					["auto", "show", "hide"], {"auto": "Auto-hide", "show": "Always show", "hide": "Always hide"}),
			]) + _section("Performance", [
				_choice("Reduce motion", "Skips transitions and animations", preload("res://assets/icons/motion.svg"), "theme", "reduce_motion",
					["system", "always", "never"], {"system": "System", "always": "Always", "never": "Never"}),
				_choice("Battery saving", "Reduces animations while the app stays idle or doesn't have focus", preload("res://assets/icons/battery3.svg"), "performance", "battery_saving",
					["light", "medium", "strong"], {"light": "Light", "medium": "Medium", "strong": "Strong"}),
				_choice("Frame rate", "Select the framerate of the app", preload("res://assets/icons/fps.svg"), "performance", "max_fps",
					[30, 60, 120, 144, 0], {30: "30 fps", 60: "60 fps", 120: "120 fps", 144: "144 fps", 0: "Unlimited"}),
				_choice("Background quality", "Select how often the animated background moves", preload("res://assets/icons/fps.svg"), "performance", "background_quality",
					["high", "medium", "low"], {"high": "High", "medium": "Medium", "low": "Low"}),
				_choice("Video decoding", "How animated backgrounds and covers are decoded", preload("res://assets/icons/fps.svg"), "performance", "video_decoding",
					["auto", "software"], {"auto": "Hardware when available", "software": "Software only"}),
			])
		"lyrics":
			return _section("Sources", [SettingsScreen.lyrics_provider_entry(SettingItem.refresh_list.bind(list))]) + _section("Display", [
				SettingItem.toggle("Show romaji", "Adds a romanized line to supported lyrics", preload("res://assets/icons/romaji.svg"), "lyrics", "show_romaji"),
			])
		"library":
			return SettingsScreen.library_entries(false)
		"integrations":
			return _section("Discord", _discord_entries()) + _section("Scrobbling", ScrobbleLogin.SERVICES.keys().map(_scrobble_entry))
		"plugins":
			return _plugin_entries()
		"themes":
			return _theme_entries()
		"about":
			return []
		"plugin":
			var plugin: NariPlugin = Plugins.get_plugin(str(data.get("plugin", "")))
			return plugin.settings_entries() if plugin else []
		"theme":
			var id := str(data.get("theme", ""))
			return Themes.settings_for(id).map(_theme_setting_entry.bind(id))
	var categories: Array = []
	for row in [
		["General", "Screens and startup", preload("res://assets/icons/more.svg"), "general"],
		["Library", "Build your library", preload("res://assets/icons/library.svg"), "library"],
		["Playback", "Volume and playback", preload("res://assets/icons/music_note.svg"), "playback"],
		["Appearance", "Change how the app looks", preload("res://assets/icons/theme.svg"), "appearance"],
		["Lyrics", "Where your lyrics come from", preload("res://assets/icons/lyrics.svg"), "lyrics"],
		["Integrations", "Discord and scrobbling", INTEGRATIONS_ICON, "integrations"],
		["Plugins", "Add features made by others", PLUGIN_ICON, "plugins"],
		["About", "Version and links", preload("res://assets/icons/nari.svg"), "about"],
	]:
		var entry := {
			"title": row[0],
			"description": row[1],
			"icon": row[2],
			"action": Main.change_page.bind(Main.Pages.About) if row[3] == "about" else Main.change_page.bind(Main.Pages.Settings, {"category": row[3]}),
		}
		var resets: Array = _entries_of(row[3]).filter(func(child: Dictionary): return child.has("reset"))
		if not resets.is_empty():
			entry["reset"] = func():
				for child in resets:
					child["reset"].call()
		categories.append(entry)
	return categories

static func _confirm_provider(provider: MusicProvider) -> void:
	var dialog := Dialog.menu("Switch to %s?" % provider.display_name, "Your library changes and the music stops")
	dialog.add_button("Cancel")
	dialog.add_button("Switch", func():
		MediaPlayer.stop()
		MediaPlayer.use_provider(provider.id), Dialog.Style.PRIMARY)
	dialog.popup()

static func _section(name: String, entries: Array) -> Array:
	for entry: Dictionary in entries:
		entry["section"] = name
	return entries

static func dual_screen_entry() -> Dictionary:
	if OS.has_feature("pc"):
		return SettingItem.toggle("Dual-screen window", "Opens the bottom screen in its own window, for a second monitor or a touch display", preload("res://assets/icons/music_note_dual.svg"), "general", "dual_screen")
	return SettingItem.toggle("Dual-screen integration", "Uses both screens when a second one is connected (HDMI or cast)", preload("res://assets/icons/music_note_dual.svg"), "general", "dual_screen")

static func lyrics_provider_entry(refresh: Callable) -> Dictionary:
	return {
		"title": "Lyrics provider",
		"description": "Choose where your lyrics come from",
		"icon": preload("res://assets/icons/lyrics.svg"),
		"value": func(): return "%d active" % SettingsManager.lyrics.providers.size(),
		"action": func():
			var dialog := Dialog.menu("Lyrics provider")
			var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
			list.separation = 0
			list.follow_focus = true
			dialog.content.add_child(list)
			dialog.closed.connect(refresh)
			dialog.popup()
			list.set_items(MediaPlayer.lyrics.providers, func(provider: LyricsProvider) -> NariButton:
				return dialog.make_toggle(provider.display_name, SettingsManager.lyrics.providers.has(provider.id),
					func(enabled: bool): SettingsManager.lyrics.set_provider(provider.id, enabled), preload("res://assets/icons/lyrics.svg")))
			list.custom_minimum_size.y = list.container.cell_height * minf(MediaPlayer.lyrics.providers.size(), ItemMenu.VISIBLE_OPTIONS)
			dialog.add_button("Accept", Callable(), Dialog.Style.PRIMARY),
		"reset": func(): SettingsManager.lyrics.reset("providers"),
	}

static func home_entries_entry(refresh: Callable) -> Dictionary:
	return {
		"title": "Home entries",
		"description": "Choose which entries the home carousel shows",
		"icon": preload("res://assets/icons/home.svg"),
		"value": func(): return "%d hidden" % SettingsManager.theme.hidden_home.size(),
		"action": func():
			var dialog := Dialog.menu("Home entries")
			var list: ScrollList = ItemMenu.SCROLL_LIST.instantiate()
			list.separation = 0
			list.follow_focus = true
			dialog.content.add_child(list)
			dialog.closed.connect(refresh)
			dialog.popup()
			var entries := HomeView.entries(true).filter(func(entry: Dictionary): return entry.get("page") != Main.Pages.Settings)
			list.set_items(entries, func(entry: Dictionary) -> NariButton:
				var key := HomeView.key(entry)
				return dialog.make_toggle(str(entry["title"]), not SettingsManager.theme.hidden_home.has(key), func(enabled: bool):
					var hidden := Array(SettingsManager.theme.hidden_home)
					hidden.erase(key)
					if not enabled:
						hidden.append(key)
					SettingsManager.theme.hidden_home = PackedStringArray(hidden), entry["icon"]))
			list.custom_minimum_size.y = list.container.cell_height * minf(entries.size(), ItemMenu.VISIBLE_OPTIONS)
			dialog.add_button("Accept", Callable(), Dialog.Style.PRIMARY),
		"reset": func(): SettingsManager.theme.reset("hidden_home"),
	}

static func library_entries(setup: bool) -> Array:
	var entries: Array = _section("Source", [{
		"title": "Music provider",
		"description": "Choose where your music library comes from",
		"icon": preload("res://assets/icons/music_library.svg"),
		"value": func(): return MediaPlayer.provider.display_name if MediaPlayer.provider else "None",
		"action": func():
			var dialog := Dialog.menu("Music provider")
			for provider in MediaPlayer.providers:
				dialog.add_option(provider.display_name, MediaPlayer.use_provider.bind(provider.id) if setup or provider == MediaPlayer.provider else _confirm_provider.bind(provider), provider.icon if provider.icon else preload("res://assets/icons/music_library.svg"))
			if setup:
				var more := NariLabel.new()
				more.text = "Want more providers? Try installing a plugin on Settings!"
				more.font_size = 32
				more.weight = 600
				more.modulate.a = 0.6
				more.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				more.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				dialog.footer.add_child(more)
				dialog.footer.show()
			dialog.popup(),
	}])
	if MediaPlayer.provider:
		for entry: Dictionary in MediaPlayer.provider.setup_entries() if setup else MediaPlayer.provider.settings_entries():
			entry["section"] = entry.get("section", MediaPlayer.provider.display_name)
			entries.append(entry)
	if not setup:
		entries.append_array(_section("Library", [SettingItem.toggle("Artist info from the internet", "Gets artist photos, bios and listener counts from Deezer and Last.fm", preload("res://assets/icons/artist.svg"), "library", "artist_info")]))
		entries.append_array(_section("History", [{
			"title": "Clear listening history",
			"description": "Forgets what you played, used for Discover",
			"icon": preload("res://assets/icons/delete.svg"),
			"value": func(): return MediaPlayer.format_song_count(MediaPlayer.get_history().size()),
			"action": func(): Dialog.confirm("Clear your listening history?", "Clear", MediaPlayer.clear_history, true),
		}]))
	return entries

func _plugin_entries() -> Array:
	var entries: Array = [_search_entry("plugins"), {
		"title": "Install plugin",
		"section": "Get more",
		"description": "Adds a plugin from a .zip file",
		"icon": preload("res://assets/icons/add.svg"),
		"action": func():
			var dialog := Dialog.menu("Plugins can run any code", "Only install plugins from people you trust")
			dialog.add_button("Cancel")
			dialog.add_button("Choose a .zip", Plugins.pick, Dialog.Style.PRIMARY)
			dialog.popup(),
	}, _auto_update_entry()]
	var ids: Array = Plugins.manifests.keys()
	ids.sort_custom(func(first: String, second: String):
		if Plugins.is_marked(first) != Plugins.is_marked(second):
			return Plugins.is_marked(first)
		return str(Plugins.manifests[first]["name"]).naturalnocasecmp_to(str(Plugins.manifests[second]["name"])) < 0)
	for id: String in ids:
		var manifest: Dictionary = Plugins.manifests[id]
		var plugin: NariPlugin = Plugins.get_plugin(id)
		entries.append({
			"title": str(manifest["name"]),
			"description": _updatable(id, str(manifest.get("description", ""))),
			"icon": PLUGIN_ICON,
			"image": Plugins.image_of(id),
			"plugin": id,
			"section": "Installed",
			"enabled": Plugins.is_marked(id) and Plugins.is_approved(id),
			"action": PluginInfo.open.bind(id),
			"settings": Main.change_page.bind(Main.Pages.Settings, {"category": "plugin", "plugin": id}) if plugin and plugin.has_settings() else Callable(),
		})
	return entries

func _adapt_entry() -> Dictionary:
	var entry := SettingItem.toggle("Colors adapt to song", "Tints the app with the colors of the current song (if available)", preload("res://assets/icons/auto_theme.svg"), "theme", "adapt_to_song")
	if ThemeEngine.adapt_mode == "allow":
		return entry
	var forced := ThemeEngine.adapt_mode == "force"
	entry["description"] = "Your theme keeps this %s" % ("on" if forced else "off")
	entry["value"] = func(): return "On" if forced else "Off"
	entry["checked"] = func(): return forced
	entry["action"] = func(): Dialog.confirm("%s decides the colors, apply another theme to change this" % Themes.active.get("name", "Your theme"), "OK", Callable())
	entry.erase("reset")
	return entry

func _theme_entries() -> Array:
	var entries: Array = [_search_entry("themes"), {
		"title": "Install theme",
		"section": "Get more",
		"description": "Adds a theme from a .naritheme file",
		"icon": preload("res://assets/icons/add.svg"),
		"action": Themes.pick,
	}, _auto_update_entry(), {
		"title": "Default",
		"description": "The look Nari ships with",
		"icon": preload("res://assets/icons/nari.svg"),
		"plugin": "",
		"section": "Installed",
		"enabled": Themes.active_id().is_empty(),
		"action": Themes.activate.bind(""),
	}]
	var ids: Array = Themes.manifests.keys()
	ids.sort_custom(func(first: String, second: String):
		if Themes.is_builtin(first) != Themes.is_builtin(second):
			return Themes.is_builtin(first)
		return str(Themes.manifests[first]["name"]).naturalnocasecmp_to(str(Themes.manifests[second]["name"])) < 0)
	for id: String in ids:
		var manifest: Dictionary = Themes.manifests[id]
		var description := str(manifest.get("description", ""))
		var active := Themes.active_id() == id
		entries.append({
			"title": str(manifest["name"]),
			"description": _updatable(id, description),
			"icon": preload("res://assets/icons/background.svg"),
			"image": Themes.image_of(id),
			"plugin": id,
			"section": "Installed",
			"enabled": active,
			"action": Themes.activate.bind(id) if Themes.is_builtin(id) else PluginInfo.open.bind(id, Themes),
			"settings": Main.change_page.bind(Main.Pages.Settings, {"category": "theme", "theme": id}) if active and not Themes.settings_for(id).is_empty() else Callable(),
		})
	return entries

func _theme_setting_entry(setting: Dictionary, id: String) -> Dictionary:
	var key := str(setting["id"])
	var section := Themes.settings_section(id)
	var entry := {
		"title": str(setting.get("name", key)),
		"description": str(setting.get("description", "")),
		"icon": preload("res://assets/icons/theme.svg"),
		"value": func(): return Themes.setting_label(id, setting),
		"action": func(): SettingsManager.set_value(section, key, Themes.next_setting_value(id, setting)),
		"reset": func(): SettingsManager.set_value(section, key, setting.get("default")),
	}
	var labels := Themes.setting_options(setting).map(func(option: Dictionary): return str(option.get("name", option.get("id", ""))))
	if str(setting.get("type", "")) == "choice" and not labels.all(func(label: String): return label in ["On", "Off"]):
		entry.erase("action")
		entry["choices"] = {
			"options": Themes.setting_options(setting).map(func(option: Dictionary): return {"value": str(option.get("id", "")), "label": str(option.get("name", option.get("id", "")))}),
			"get": func(): return str(Themes.setting_value(id, key)),
			"set": func(option: Variant): SettingsManager.set_value(section, key, option),
		}
	if str(setting.get("type", "")) == "number":
		var suffix := str(setting.get("suffix", ""))
		entry["slider"] = {
			"min": float(setting.get("min", 0.0)),
			"max": float(setting.get("max", 100.0)),
			"step": float(setting.get("step", 1.0)),
			"get": func(): return float(Themes.setting_value(id, key)),
			"set": func(amount: float): SettingsManager.set_value(section, key, amount),
			"format": func(amount: float): return _number(amount) + suffix,
		}
	return entry

func _search_entry(kind: String) -> Dictionary:
	return {
		"title": "Search marketplace",
		"section": "Get more",
		"description": "Find %s made by the community and install them right here" % kind,
		"icon": preload("res://assets/icons/marketplace.svg"),
		"action": Main.change_page.bind(Main.Pages.Marketplace, {"kind": kind}),
	}

func _auto_update_entry() -> Dictionary:
	var entry := SettingItem.toggle("Auto-update marketplace addons", "Updates the plugins and themes you got from the marketplace when Nari starts", preload("res://assets/icons/download.svg"), "plugins", "auto_update")
	entry["section"] = "Get more"
	return entry

func _updatable(id: String, description: String) -> String:
	return "Update available · " + description if Marketplace.has_update(id) else description

func _discord_entries() -> Array:
	return [
		SettingItem.toggle("Show Rich Presence", "Shows the song you are playing on your Discord profile", preload("res://assets/icons/discord.svg"), "discord", "enabled"),
		_choice("Status name", "What your friends see after \"Listening to\"", preload("res://assets/icons/edit.svg"), "discord", "status_name", DISCORD_NAMES.keys(), DISCORD_NAMES),
		SettingItem.toggle("Show when paused", "Keeps the status on your profile while the song is paused", preload("res://assets/icons/play.svg"), "discord", "show_paused"),
		SettingItem.toggle("Fetch artwork", "Looks up the cover on Deezer when the music source doesn't share one", preload("res://assets/icons/image.svg"), "discord", "fetch_artwork"),
		_discord_buttons_entry(),
	]

func _discord_buttons_entry() -> Dictionary:
	var discord: Object = SettingsManager.discord
	return {
		"title": "Rich status buttons",
		"description": "Choose which links show under your Rich Presence",
		"icon": preload("res://assets/icons/info.svg"),
		"value": func(): return "%d active" % DISCORD_BUTTONS.keys().filter(func(key: String): return discord.get(key)).size(),
		"action": func():
			var dialog := Dialog.menu("Rich status buttons")
			for key: String in DISCORD_BUTTONS:
				dialog.add_toggle(DISCORD_BUTTONS[key], discord.get(key), func(enabled: bool): discord.set(key, enabled), DISCORD_BUTTON_ICONS[key])
			dialog.closed.connect(SettingItem.refresh_list.bind(list))
			dialog.add_button("Accept", Callable(), Dialog.Style.PRIMARY)
			dialog.popup(),
		"reset": func():
			for key: String in DISCORD_BUTTONS:
				discord.reset(key),
	}

func _scrobble_entry(service: String) -> Dictionary:
	var service_name: String = ScrobbleLogin.SERVICES[service]
	return {
		"title": service_name,
		"description": "Sends every song you listen to to your %s profile" % service_name,
		"icon": SCROBBLE_ICONS.get(service, preload("res://assets/icons/headphones.svg")),
		"value": func(): return str(ScrobbleLogin.accounts().get(service, "Off")),
		"action": func():
			if not ScrobbleLogin.accounts().has(service):
				ScrobbleLogin.open(service)
				return
			Dialog.confirm("Disconnect %s?" % service_name, "Disconnect", func():
				Engine.get_singleton("MusicService").scrobbleDisconnect(service), true),
	}

func _on_scrobble_account_changed(_service: String, _error: String) -> void:
	SettingItem.refresh_list(list)

func _on_install_finished(error: String, kind: String) -> void:
	var dialog := Dialog.menu("%s installed" % kind if error.is_empty() else "Couldn't install the %s" % kind.to_lower(), error)
	dialog.add_button("OK", Callable(), Dialog.Style.PRIMARY)
	dialog.popup()

func _choice(title: String, description: String, icon: Texture2D, section: String, key: String, options: Array, names: Dictionary) -> Dictionary:
	var settings: Object = SettingsManager.get(section)
	var entry := {
		"title": title,
		"description": description,
		"icon": icon,
		"value": func(): return str(names.get(settings.get(key), settings.get(key))),
		"reset": func(): settings.reset(key),
	}
	if options.all(func(option: Variant): return option is bool):
		entry["action"] = func(): settings.set(key, options[(options.find(settings.get(key)) + 1) % options.size()])
		return entry
	entry["choices"] = {
		"options": options.map(func(option: Variant): return {"value": option, "label": str(names.get(option, option))}),
		"get": func(): return settings.get(key),
		"set": func(option: Variant): settings.set(key, option),
	}
	return entry

func _slider(title: String, description: String, icon: Texture2D, section: String, key: String, bounds: Vector3, format: Callable) -> Dictionary:
	var settings: Object = SettingsManager.get(section)
	return {
		"title": title,
		"description": description,
		"icon": icon,
		"value": func(): return format.call(float(settings.get(key))),
		"slider": {
			"min": bounds.x,
			"max": bounds.y,
			"step": bounds.z,
			"get": func(): return float(settings.get(key)),
			"set": func(amount: float): settings.set(key, amount),
			"format": format,
		},
		"reset": func(): settings.reset(key),
	}

static func _number(amount: float) -> String:
	return str(int(amount)) if is_equal_approx(amount, roundf(amount)) else str(snappedf(amount, 0.01))

func _resolution_choice() -> Dictionary:
	var screen := DisplayServer.screen_get_size(get_window().current_screen)
	var options: Array = [""] + RESOLUTIONS.filter(func(entry: String):
		var parts := entry.split("x")
		return int(parts[0]) <= screen.x and int(parts[1]) <= screen.y)
	return _choice("Resolution", "The resolution used in exclusive fullscreen", preload("res://assets/icons/fps.svg"), "general", "resolution",
		options, {"": "Native (%dx%d)" % [screen.x, screen.y]})

func _select(index: int) -> void:
	if index == _selected or index < 0 or index >= _entries.size() or _entries[index].has("header"):
		return
	var first := _selected < 0
	_selected = index
	if _caption_fade:
		_caption_fade.kill()
	if first:
		_write_caption()
		return
	_caption_fade = UI.crossfade([showcase], CAPTION_FADE, _write_caption)

func _write_caption() -> void:
	var image: Texture2D = _entries[_selected].get("image")
	picture.visible = image != null
	if image:
		picture.texture = image
	glyph.texture = null if image else _entries[_selected].get("icon")
	caption_title.text = str(_entries[_selected].get("title", ""))
	caption_description.text = str(_entries[_selected].get("description", ""))
	var entry: Dictionary = _entries[_selected]
	if Main.get_page() and Main.get_page() != self:
		return
	Main.set_shortcuts([{"glyph": InputGlyphs.Glyph.X, "action": func():
		Dialog.confirm("Reset to default values?", "Reset", func():
			entry["reset"].call()
			SettingItem.refresh_list(list))}] if entry.has("reset") else [])
