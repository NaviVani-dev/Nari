extends Node

signal themes_changed
signal install_finished(error: String)
signal backgrounds_changed
signal stage_changed

const DIR: = "user://themes"
const STAGING_DIR: = "user://theme_staging"
const MEDIA_WAIT_MSEC: = 1500
const API: = 1
const ASSETS_FOLDER: = "assets"
const GLYPHS_FOLDER: = "glyphs"
const ICONS_TARGET: = "res://assets/icons"
const SCRIPT_FILE: = "main.lua"
const SCRIPT_PREFIX: = "theme_"
const IMPORT_DEPTH: = 8
const STYLE_KINDS: = ["panel", "button", "progress"]
const AXIS_STRETCH: = {"stretch": StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH, "tile": StyleBoxTexture.AXIS_STRETCH_MODE_TILE, "tile_fit": StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT}
const FILTERS: = {"nearest": CanvasItem.TEXTURE_FILTER_NEAREST, "linear": CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS}
const ADAPT_MODES: = ["allow", "off", "force"]
const GLYPH: = preload("res://assets/icons/theme.svg")
const LOOK_KEYS: = ["styles", "shape", "font", "font_pixelated", "font_shadow", "mode", "adapt", "icons_colored", "filters", "icons", "glyphs", "shaders"]
const IMAGE_EXTENSIONS: = ["png", "jpg", "jpeg", "webp"]
const LAYER_TYPES: = ["color", "blobs", "tint", "triangles", "dots", "image", "cover", "shader"]
const DEFAULT_LAYERS: = [{"type": "color"}, {"type": "blobs"}, {"type": "tint"}, {"type": "triangles"}, {"type": "dots"}]
const LIVE_KEYS: = ["uniforms", "clocks", "transition", "dim", "opacity", "on", "not_on", "color"]
const BUILTIN: = {
	"dark": {
		"id": "dark",
		"name": "Dark",
		"author": "Nari",
		"description": "Nari's colors on a deep navy background",
		"api": API,
		"mode": "dark",
		"resource": "res://assets/themes/dark.tres",
	},
}

var manifests: = {}
var active: = {}
var layers: Array[Dictionary] = []
var overlays: Array[Dictionary] = []
var glyphs: = {}
var styles: = {}
var _samplers: = {}
var _shaders: = {}
var _textures: = {}
var _texture_root: = ""
var _random_picks: = {}
var _song_id: = ""
var _page: = "home"
var _follows_page: = false
var _swapped: = {}
var _held: = {}
var _players: = {}
var _script: NariPlugin
var _script_theme: = ""
var _script_overrides: = {}
var _script_settings: Array[Dictionary] = []
var _script_starting: = false
var _booted: = false
var _l: = Log.new("Themes", Color("c58af2"))

func _ready() -> void :
	DirAccess.make_dir_recursive_absolute(DIR)
	_scan()
	_apply(false)
	_boot.call_deferred()
	SettingsManager.changed.connect( func(section: String, key: String, value: Variant):
		if section == "theme" and key == "active":
			_apply(true)
		elif section == "performance" and key == "background":
			_hold_still()
		elif section == "performance" and key == "video_decoding":
			_reload_media()
		elif section == settings_section(active_id()):
			if _script:
				_script.emit_event("setting", [key, value])
			_repaint())
	MediaPlayer.playback_changed.connect( func(_state: Dictionary): _follow_song())
	Main.page_changed.connect( func(page: int, _data: Dictionary): _follow_page(page))
	Plugins.plugin_failed.connect(_on_script_failed)
	if Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").connect("theme_picked", func(path: String):
			if not path.is_empty():
				install_finished.emit(install(path)))

func _boot() -> void :
	_booted = true
	var manifest: Dictionary = manifests.get(active_id(), {})
	_start_script(manifest)
	if _script:
		active = _resolve(manifest)
		_paint(false)

func active_id() -> String:
	return str(active.get("id", ""))

func current_page() -> String:
	return _page

func pick() -> void :
	if Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").pickTheme()

func install(zip_path: String) -> String:
	var root: = Package.extract(zip_path, STAGING_DIR)
	if root.is_empty():
		return "The file is not a zip archive"
	var manifest: = read_manifest(root)
	var id: = str(manifest.get("id", ""))
	var problem: = Package.problem(manifest, id, API)
	if problem.is_empty():
		problem = Package.id_problem(id)
	if problem.is_empty() and BUILTIN.has(id):
		problem = "its id is taken by a theme that comes with Nari"
	if not problem.is_empty():
		Package.remove(STAGING_DIR)
		return "This theme can't be installed: %s" % problem
	var target: = DIR.path_join(id)
	if id == _script_theme:
		_stop_script()
	Package.remove(target)
	var moved: = DirAccess.rename_absolute(root, target)
	Package.remove(STAGING_DIR)
	if moved != OK:
		return "Nari could not write the theme files"
	DirAccess.remove_absolute(zip_path)
	_l.log("Installed theme '%s' %s" % [id, manifest.get("version", "")])
	_warn_unplayable(target)
	_scan()
	if id == active_id():
		_apply(true)
	return ""

func _warn_unplayable(root: String) -> void :
	if not MotionPlayer.available():
		return
	var checked: = PackedStringArray()
	for layer in layers_of(read_manifest(root)):
		var file: = str(layer.get("file", ""))
		if str(layer["type"]) != "image" or file.is_empty() or checked.has(file):
			continue
		checked.append(file)
		var problem: String = ClassDB.class_call_static("NariMotion", "probe", ProjectSettings.globalize_path(root.path_join(file)))
		if not problem.is_empty():
			_l.warn("The theme background '%s' can't be played on this device: %s" % [file, problem])

func is_builtin(id: String) -> bool:
	return BUILTIN.has(id)

func uninstall(id: String) -> void :
	if is_builtin(id):
		return
	if id == active_id():
		SettingsManager.theme.active = ""
	Package.remove(DIR.path_join(id))
	var data: = Plugins.DATA_DIR.path_join(script_id(id))
	Package.remove(data)
	for extension in ["json", "private"]:
		DirAccess.remove_absolute("%s.%s" % [data, extension])
	_l.log("Uninstalled theme '%s'" % id)
	_scan()

func apply_problem(id: String) -> String:
	return Package.version_problem(manifests.get(id, {}), id)

func activate(id: String) -> void :
	SettingsManager.theme.active = id

func image_of(id: String) -> Texture2D:
	var manifest: Dictionary = manifests.get(id, {})
	var image: = NariPlugin.load_file(str(manifest["path"]).path_join(str(manifest["icon"]))) as Texture2D if manifest.has("icon") else null
	return image if image else Package.placeholder(GLYPH, theme_of(manifest))

func screenshot_sources(id: String) -> PackedStringArray:
	return Package.sources(manifests.get(id, {}), "screenshots")

func load_screenshot(id: String, source: String) -> Texture2D:
	return await Plugins.load_screenshot(id, source)

func wait_for_media() -> void :
	for player: MotionPlayer in _players.values():
		player.prime(MEDIA_WAIT_MSEC)

static func read_manifest(root: String) -> Dictionary:
	return _with_imports(root, Package.manifest_at(root), {}, 0)

static func _with_imports(root: String, manifest: Dictionary, seen: Dictionary, depth: int) -> Dictionary:
	var own: = manifest.duplicate(true)
	var listed: Variant = own.get("imports", [])
	own.erase("imports")
	if not listed is Array or depth >= IMPORT_DEPTH:
		return own
	var merged: = {}
	for entry: Variant in listed:
		var relative: = str(entry).simplify_path()
		if relative.is_empty() or relative.begins_with("..") or relative.is_absolute_path() or seen.has(relative):
			continue
		seen[relative] = true
		var part: = JsonUtil.parse_dict(FileAccess.get_file_as_string(root.path_join(relative)))
		merged = _merge(merged, _with_imports(root, part, seen, depth + 1))
	return _merge(merged, own)

func _scan() -> void :
	manifests = BUILTIN.duplicate(true)
	for folder in DirAccess.get_directories_at(DIR):
		if is_builtin(folder):
			continue
		var path: = DIR.path_join(folder)
		var manifest: = read_manifest(path)
		var problem: = Package.problem(manifest, folder, API)
		if not problem.is_empty():
			_l.warn("Skipped theme '%s': %s" % [folder, problem])
			continue
		manifest["path"] = path
		manifests[folder] = manifest
	themes_changed.emit()

func _apply(animate: bool) -> void :
	var id: = SettingsManager.theme.active
	if not id.is_empty() and not manifests.has(id):
		_l.warn("The theme '%s' isn't installed, using the default look" % id)
	var manifest: Dictionary = manifests.get(id, {})
	var problem: = apply_problem(id) if not manifest.is_empty() else ""
	if not problem.is_empty():
		_l.warn("Using the default look: %s" % problem)
		manifest = {}
	_start_script(manifest)
	active = _resolve(manifest)
	_paint(animate)
	if not active.is_empty():
		_l.log("Applied theme '%s' %s" % [id, active.get("version", "")])

func _paint(animate: bool) -> void :
	_swap_assets()
	_load_glyphs()
	_load_styles()
	var adapt: = str(active.get("adapt", "allow"))
	ThemeEngine.adapt_mode = adapt if ADAPT_MODES.has(adapt) else "allow"
	ThemeEngine.dark_mode = str(active.get("mode", "light")) == "dark"
	ThemeEngine.icons_colored = bool(active.get("icons_colored", false))
	var shape: Dictionary = _dict(active, "shape")
	ThemeEngine.shape_radius = float(shape.get("radius", 1.0))
	ThemeEngine.shape_blur = float(shape.get("gradient_blur", 1.0))
	ThemeEngine.font_shadow = clampf(float(active.get("font_shadow", 0.0)), 0.0, 0.5)
	ThemeEngine.set_fonts(_fonts())
	ThemeEngine.set_base(theme_of(active), animate)
	var input_glyphs: Node = get_node_or_null("/root/InputGlyphs")
	if input_glyphs:
		input_glyphs.refresh_glyphs()
	_load_backgrounds()
	themes_changed.emit()

func _repaint() -> void :
	_restyle(true)
	stage_changed.emit()

func _restyle(announce: bool) -> void :
	var previous: = active
	active = _resolve(manifests.get(active_id(), {}))
	if active == previous:
		return
	if LOOK_KEYS.any( func(key: String): return active.get(key) != previous.get(key)):
		_paint(true)
		return
	ThemeEngine.set_base(theme_of(active), true)
	if _structure(active) != _structure(previous):
		_load_backgrounds()
	else:
		layers = layers_of(active)
		overlays = overlays_of(active)
		stage_changed.emit()
	if announce:
		themes_changed.emit()

static func _structure(manifest: Dictionary) -> Array:
	var found: = []
	for entry in layers_of(manifest) + overlays_of(manifest):
		var shape: = entry.duplicate()
		for key in LIVE_KEYS:
			shape.erase(key)
		found.append(shape)
	return found

func _follow_song() -> void :
	var song_id: = str(MediaPlayer.get_current_song().get("id", ""))
	if song_id == _song_id:
		return
	_song_id = song_id
	if not _random_picks.is_empty():
		_random_picks.clear()
		_repaint()

func _follow_page(page: int) -> void :
	_page = str(Main.PAGE_SCENES.get(page, "")).to_lower()
	if not _follows_page:
		return
	_restyle(false)

static func settings_section(id: String) -> String:
	return "theme:" + id

static func settings_of(manifest: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var listed: Variant = manifest.get("settings", [])
	for setting: Variant in listed if listed is Array else []:
		if setting is Dictionary and not str(setting.get("id", "")).is_empty():
			found.append(setting)
	return found

func settings_for(id: String) -> Array[Dictionary]:
	var found: = settings_of(manifests.get(id, {}))
	if id != _script_theme:
		return found
	var taken: = {}
	for setting in found:
		taken[str(setting["id"])] = true
	for setting in _script_settings:
		if not taken.has(str(setting["id"])):
			found.append(setting)
	return found

func setting_value(id: String, key: String) -> Variant:
	for setting in settings_for(id):
		if str(setting["id"]) == key:
			return SettingsManager.get_value(settings_section(id), key, setting.get("default"))
	return null

func setting_label(id: String, setting: Dictionary) -> String:
	var value: Variant = setting_value(id, str(setting["id"]))
	if str(setting.get("type", "")) == "choice":
		for option in _options_of(setting):
			if str(option.get("id", "")) == str(value):
				return str(option.get("name", value))
		return str(value)
	var number: = float(value)
	return "%s%s" % [str(int(number)) if is_equal_approx(number, roundf(number)) else str(number), setting.get("suffix", "")]

func next_setting_value(id: String, setting: Dictionary) -> Variant:
	var value: Variant = setting_value(id, str(setting["id"]))
	if str(setting.get("type", "")) == "choice":
		var ids: = _options_of(setting).map(func(option: Dictionary): return str(option.get("id", "")))
		return ids[(ids.find(str(value)) + 1) % ids.size()] if not ids.is_empty() else value
	var step: = float(setting.get("step", 1.0))
	var next: = snappedf(float(value) + step, step)
	return float(setting.get("min", 0.0)) if next > float(setting.get("max", 100.0)) else next

static func setting_options(setting: Dictionary) -> Array[Dictionary]:
	return _options_of(setting)

static func _options_of(setting: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var listed: Variant = setting.get("options", [])
	for option: Variant in listed if listed is Array else []:
		if option is Dictionary:
			found.append(option)
	return found

func _option_of(setting: Dictionary, value: Variant) -> Dictionary:
	var options: = _options_of(setting)
	for option in options:
		if str(option.get("id", "")) == str(value):
			var pages: Variant = option.get("pages")
			if pages is Dictionary:
				_follows_page = true
				return _fixed_option(options, str(pages.get(_page, pages.get("default", ""))))
			if not bool(option.get("random", false)):
				return option
			var key: = str(setting["id"])
			if not _random_picks.has(key):
				var fixed: = options.filter(func(candidate: Dictionary): return not bool(candidate.get("random", false)) and not candidate.has("pages"))
				_random_picks[key] = fixed.pick_random() if not fixed.is_empty() else {}
			return _random_picks[key]
	return {}

func _fixed_option(options: Array[Dictionary], id: String) -> Dictionary:
	for option in options:
		if str(option.get("id", "")) == id and not option.has("pages") and not bool(option.get("random", false)):
			return option
	return {}

static func overrides_of(option: Dictionary) -> Dictionary:
	var overrides: Variant = option.get("overrides", option.get("patch", {}))
	return overrides if overrides is Dictionary else {}

func _resolve(manifest: Dictionary) -> Dictionary:
	var resolved: = manifest
	_follows_page = false
	var id: = str(manifest.get("id", ""))
	for setting in settings_for(id):
		if str(setting.get("type", "")) != "choice":
			continue
		var value: Variant = SettingsManager.get_value(settings_section(id), str(setting["id"]), setting.get("default"))
		resolved = _merge(resolved, overrides_of(_option_of(setting, value)))
	var pages: Variant = manifest.get("pages", {})
	if pages is Dictionary and not pages.is_empty():
		_follows_page = true
		var on_page: Variant = pages.get(_page, {})
		if on_page is Dictionary:
			resolved = _merge(resolved, on_page)
	if not id.is_empty() and id == _script_theme:
		resolved = _merge(resolved, _script_overrides)
	return resolved

static func _merge(base: Dictionary, overrides: Dictionary) -> Dictionary:
	return _merged(base, overrides)

static func _merged(base: Variant, overrides: Variant) -> Variant:
	if base is Dictionary and overrides is Dictionary:
		var merged: Dictionary = base.duplicate(true)
		for key: Variant in overrides:
			merged[key] = _merged(merged.get(key), overrides[key])
		return merged
	if base is Array and overrides is Dictionary and _has_ids(base):
		var merged: Array = base.duplicate(true)
		for key: Variant in overrides:
			for index in merged.size():
				if merged[index] is Dictionary and str(merged[index].get("id", "")) == str(key):
					merged[index] = _merged(merged[index], overrides[key])
		return merged
	if overrides is Dictionary or overrides is Array:
		return overrides.duplicate(true)
	return overrides

static func _has_ids(list: Array) -> bool:
	return list.any(func(entry: Variant): return entry is Dictionary and entry.has("id"))

static func layers_of(manifest: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var listed: Variant = manifest.get("background")
	if listed == null:
		for entry: Dictionary in DEFAULT_LAYERS:
			found.append(entry.duplicate())
		return found
	if listed is Dictionary and not listed.has("type"):
		return _legacy_layers(listed)
	for entry: Variant in [listed] if listed is Dictionary else listed if listed is Array else []:
		if entry is Dictionary and str(entry.get("type", "")) in LAYER_TYPES:
			found.append(entry)
	return found

static func _legacy_layers(settings: Dictionary) -> Array[Dictionary]:
	var procedural: = _dict(settings, "procedural")
	var shader: = _dict(settings, "shader")
	var now_playing: = _dict(settings, "now_playing")
	var found: Array[Dictionary] = [{"type": "color"}]
	if not str(shader.get("file", "")).is_empty():
		var entry: = shader.duplicate()
		entry["type"] = "shader"
		entry["id"] = "shader"
		found.append(entry)
	for kind in ["blobs", "tint", "triangles"]:
		if bool(procedural.get(kind, true)):
			found.append({"type": kind})
	var image: = {"type": "image", "fit": settings.get("fit", "cover"), "dim": settings.get("dim", 0.0)}
	var file: = str(settings.get("file", ""))
	var swaps: = not str(now_playing.get("file", "")).is_empty() or bool(now_playing.get("use_cover", false))
	var secondary: = str(_dict(settings, "secondary").get("file", ""))
	if not file.is_empty():
		var main: = image.duplicate()
		main["file"] = file
		main["id"] = "image"
		if swaps:
			main["not_on"] = ["nowplaying"]
		if not secondary.is_empty():
			main["screen"] = "top"
		found.append(main)
	if not secondary.is_empty():
		var bottom: = image.duplicate()
		bottom["file"] = secondary
		bottom["id"] = "secondary"
		bottom["screen"] = "bottom"
		if swaps:
			bottom["not_on"] = ["nowplaying"]
		found.append(bottom)
	if not str(now_playing.get("file", "")).is_empty():
		var playing: = image.duplicate()
		playing["file"] = str(now_playing["file"])
		playing["on"] = ["nowplaying"]
		found.append(playing)
	if bool(now_playing.get("use_cover", false)):
		found.append({"type": "cover", "dim": settings.get("dim", 0.0), "on": ["nowplaying"]})
	if bool(procedural.get("dots", true)):
		found.append({"type": "dots", "color": settings.get("dots_color", "")})
	return found

static func overlays_of(manifest: Dictionary) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	var listed: Variant = manifest.get("overlays", [])
	for entry: Variant in listed if listed is Array else []:
		if entry is Dictionary and not str(entry.get("file", "")).is_empty():
			found.append(entry)
	return found

const SCREENS: = ["top", "bottom"]

static func shows_on_screen(entry: Dictionary, screen: String) -> bool:
	var wanted: = str(entry.get("screen", ""))
	return not wanted in SCREENS or wanted == screen

static func screen_of(node: Node) -> String:
	var view: = node.get_viewport() if node.is_inside_tree() else null
	return "bottom" if view and view.name in ["BottomView", "BottomWindow"] else "top"

static func shows_on(layer: Dictionary, page: String) -> bool:
	var only: Variant = layer.get("on")
	if only is Array and not only.is_empty() and not page in only:
		return false
	var hidden: Variant = layer.get("not_on")
	return not (hidden is Array and page in hidden)

func uniform_value(value: Variant) -> Variant:
	if value is String:
		var text: String = value
		if text.begins_with("$"):
			return setting_value(active_id(), text.substr(1))
		if IMAGE_EXTENSIONS.has(text.get_extension().to_lower()):
			if not _samplers.has(text):
				_samplers[text] = _sampler_of(text)
			return _samplers[text]
		var field: Variant = ThemeEngine.COLOR_FIELDS.find_key(text)
		if field != null:
			return ThemeEngine.get_color(field)
		if Color.html_is_valid(text):
			return Color.html(text)
	return value

static func theme_of(manifest: Dictionary) -> ThemeResource:
	var source: String = BUILTIN.get(str(manifest.get("id", "")), {}).get("resource", ThemeEngine.DEFAULT_THEME)
	var theme: ThemeResource = (load(source) as ThemeResource).duplicate()
	var colors: = _dict(manifest, "colors")
	for field: String in ThemeEngine.COLOR_FIELDS.values():
		var value: = str(colors.get(field, ""))
		if Color.html_is_valid(value):
			theme.set(field, Color.html(value))
	return theme

static func _dict(source: Variant, key: String) -> Dictionary:
	var value: Variant = source.get(key, {}) if source is Dictionary else {}
	return value if value is Dictionary else {}

static func script_id(theme_id: String) -> String:
	return SCRIPT_PREFIX + theme_id

func is_theme_script(plugin_id: String) -> bool:
	return plugin_id.begins_with(SCRIPT_PREFIX) and manifests.has(plugin_id.trim_prefix(SCRIPT_PREFIX))

func script_name(plugin_id: String) -> String:
	return str(manifests.get(plugin_id.trim_prefix(SCRIPT_PREFIX), {}).get("name", plugin_id))

func _start_script(manifest: Dictionary) -> void :
	if not _booted:
		return
	var id: = str(manifest.get("id", ""))
	if id == _script_theme and _script:
		return
	_stop_script()
	var path: = str(manifest.get("path", ""))
	if path.is_empty() or not FileAccess.file_exists(path.path_join(SCRIPT_FILE)):
		return
	var plugin: = NariPlugin.new()
	plugin.id = script_id(id)
	plugin.name = plugin.id
	plugin.manifest = {"id": plugin.id, "name": str(manifest.get("name", id)), "path": path, "theme": id}
	add_child(plugin)
	_script = plugin
	_script_theme = id
	_script_starting = true
	var problem: = plugin.start(SCRIPT_FILE)
	_script_starting = false
	if not problem.is_empty():
		_stop_script()
		return
	if Plugins.is_nari_ready():
		plugin._on_nari_ready()
	else:
		Plugins.nari_ready.connect(plugin._on_nari_ready, CONNECT_ONE_SHOT)

func _stop_script() -> void :
	if _script:
		_script.teardown()
		_script.queue_free()
	_script = null
	_script_theme = ""
	_script_overrides = {}
	_script_settings = []

func _on_script_failed(entry: Dictionary) -> void :
	if bool(entry.get("fatal", false)) and _script and str(entry.get("id", "")) == _script.id:
		_stop_script()
		_repaint()

func script_apply(overrides: Dictionary) -> void :
	_script_overrides = overrides
	if not _script_starting:
		_repaint()

func script_settings(listed: Array) -> void :
	_script_settings = []
	for setting: Variant in listed:
		if setting is Dictionary and not str(setting.get("id", "")).is_empty():
			_script_settings.append(setting)
	if not _script_starting:
		_repaint()
		themes_changed.emit()

func _swap_assets() -> void :
	var wanted: = {}
	if active.has("path"):
		var root: = str(active["path"])
		var icons: = _dict(active, "icons")
		for name: Variant in icons:
			_collect_file(root.path_join(str(icons[name])), ICONS_TARGET.path_join(str(name) + ".svg"), wanted)
		_collect_assets(root.path_join(ASSETS_FOLDER), "res://assets", wanted)
	for path: String in _swapped.keys():
		if not wanted.has(path):
			var restored: = load(path) as DPITexture
			restored.set_source(_swapped[path])
			restored.emit_changed()
			_swapped.erase(path)
			_held.erase(path)
	for path: String in wanted:
		var texture: = load(path) as DPITexture
		if texture == null:
			_l.warn("The theme replaces '%s', but that isn't an SVG icon in Nari" % path)
			continue
		if not _swapped.has(path):
			_swapped[path] = texture.get_source()
		_held[path] = texture
		texture.set_source(wanted[path])
		texture.emit_changed()

func _collect_assets(folder: String, target: String, into: Dictionary) -> void :
	if not DirAccess.dir_exists_absolute(folder):
		return
	for name in DirAccess.get_directories_at(folder):
		if target.path_join(name) != "res://assets".path_join(GLYPHS_FOLDER):
			_collect_assets(folder.path_join(name), target.path_join(name), into)
	for name in DirAccess.get_files_at(folder):
		_collect_file(folder.path_join(name), target.path_join(name.get_basename() + ".svg"), into)

func _collect_file(file: String, replaced: String, into: Dictionary) -> void :
	var extension: = file.get_extension().to_lower()
	if not ResourceLoader.exists(replaced) or into.has(replaced) and extension != "svg":
		return
	if extension == "svg":
		into[replaced] = FileAccess.get_file_as_string(file)
	elif extension in IMAGE_EXTENSIONS:
		var wrapped: = _wrap_image(file)
		if not wrapped.is_empty():
			into[replaced] = wrapped

static func _wrap_image(path: String) -> String:
	var image: = Image.load_from_file(path)
	if image == null or image.is_empty():
		return ""
	return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d"><image width="%d" height="%d" href="data:image/png;base64,%s"/></svg>' % [
		image.get_width(), image.get_height(), image.get_width(), image.get_height(), image.get_width(), image.get_height(),
		Marshalls.raw_to_base64(image.save_png_to_buffer())]

func filter_of(relative: String) -> CanvasItem.TextureFilter:
	var filters: = _dict(active, "filters")
	var path: = relative
	while not path.is_empty():
		if filters.has(path):
			return FILTERS.get(str(filters[path]), CanvasItem.TEXTURE_FILTER_PARENT_NODE)
		path = path.get_base_dir()
	return CanvasItem.TEXTURE_FILTER_PARENT_NODE

func load_image(relative: String) -> ImageTexture:
	var image: = Image.load_from_file(str(active["path"]).path_join(relative))
	if image == null or image.is_empty():
		_l.warn("The theme image '%s' could not be loaded" % relative)
		return null
	var texture: = ImageTexture.create_from_image(image)
	texture.set_meta("filter", filter_of(relative))
	return texture

func _load_glyphs() -> void :
	glyphs = {}
	if not active.has("path"):
		return
	var root: = ASSETS_FOLDER.path_join(GLYPHS_FOLDER)
	var folder: = str(active["path"]).path_join(root)
	for device in DirAccess.get_directories_at(folder) if DirAccess.dir_exists_absolute(folder) else PackedStringArray():
		for name in DirAccess.get_files_at(folder.path_join(device)):
			var texture: = load_image(root.path_join(device).path_join(name))
			if texture:
				glyphs[device.path_join(name.get_basename())] = texture
	var listed: = _dict(active, "glyphs")
	for glyph: Variant in listed:
		var texture: = load_image(str(listed[glyph]))
		if texture:
			glyphs[str(glyph)] = texture

func _load_styles() -> void :
	styles = {}
	var listed: = _dict(active, "styles")
	for kind in STYLE_KINDS:
		var settings: = _dict(listed, kind)
		var texture: = load_image(str(settings.get("texture", ""))) if settings.has("texture") else null
		if texture == null:
			continue
		var box: = StyleBoxTexture.new()
		box.texture = texture
		var margins: = _sides(settings.get("margins", []))
		var expand: = _sides(settings.get("expand", []))
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			box.set_texture_margin(side, margins[side])
			box.set_expand_margin(side, expand[side])
		box.axis_stretch_horizontal = AXIS_STRETCH.get(str(settings.get("stretch", "stretch")), StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH)
		box.axis_stretch_vertical = box.axis_stretch_horizontal
		styles[kind] = {"box": box, "padding": _sides(settings.get("padding", [])), "modulate": bool(settings.get("modulate", true)), "filter": Icon.filter_of(texture)}
		for state in ["focus", "fill"]:
			var other: = load_image(str(settings[state])) if settings.has(state) else null
			if other:
				var alternate: = box.duplicate() as StyleBoxTexture
				alternate.texture = other
				styles[kind][state] = alternate

static func _sides(value: Variant) -> PackedFloat32Array:
	var sides: = PackedFloat32Array([0.0, 0.0, 0.0, 0.0])
	if value is Array and value.size() == 4:
		for index in 4:
			sides[index] = float(value[index])
	elif value is float or value is int:
		sides.fill(float(value))
	return sides

func _fonts() -> Dictionary:
	var listed: Variant = active.get("font", {})
	var files: Dictionary = {}
	if listed is Dictionary:
		files = listed
	elif listed is String and not listed.is_empty():
		files = {"400": listed}
	var fonts: = {}
	for weight: Variant in files:
		var file: = str(files[weight])
		var font: = FontFile.new()
		if not str(weight).is_valid_int() or font.load_dynamic_font(str(active["path"]).path_join(file)) != OK:
			_l.warn("The theme font '%s' could not be loaded" % file)
			continue
		if bool(active.get("font_pixelated", false)):
			font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
			font.hinting = TextServer.HINTING_NONE
			font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		fonts[clampi(str(weight).to_int(), 100, 900)] = font
	return fonts

func _sampler_of(relative: String) -> ImageTexture:
	var image: = Image.load_from_file(str(active.get("path", "")).path_join(relative))
	if image == null or image.is_empty():
		_l.warn("The theme image '%s' could not be loaded" % relative)
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func shader_of(file: String) -> Shader:
	if file.is_empty() or not active.has("path"):
		return null
	if _shaders.has(file):
		return _shaders[file]
	var code: = FileAccess.get_file_as_string(str(active["path"]).path_join(file))
	var loaded: Shader = null
	if code.is_empty():
		_l.warn("The theme shader '%s' could not be loaded" % file)
	else:
		loaded = Shader.new()
		loaded.code = code
	_shaders[file] = loaded
	return loaded

func draw_bar(item: CanvasItem, rect: Rect2, ratio: float, base: = Transform2D.IDENTITY) -> bool:
	var themed: Dictionary = styles.get("progress", {})
	if not themed.has("fill"):
		return false
	var track: StyleBoxTexture = themed["box"]
	var scale: = rect.size.y / maxf(track.texture.get_height(), 1.0)
	var local: = Rect2(rect.position / scale, rect.size / scale)
	if item.texture_filter != themed["filter"]:
		item.texture_filter = themed["filter"]
	item.draw_set_transform_matrix(base.scaled_local(Vector2(scale, scale)))
	item.draw_style_box(track, local)
	if ratio > 0.0:
		item.draw_style_box(themed["fill"], Rect2(local.position, Vector2(local.size.x * ratio, local.size.y)))
	item.draw_set_transform_matrix(base)
	return true

func enabled(section: String, kind: String) -> bool:
	return _dict(active, section).get(kind, true) != false

func motion_of(kind: String) -> Dictionary:
	return _dict(_dict(active, "motion"), kind)

func drift(kind: String) -> Vector3:
	var motion: = motion_of(kind)
	if motion.is_empty() or Main.reduce_motion:
		return Vector3.ZERO
	var time: = Time.get_ticks_msec() / 1000.0
	return Vector3(
		float(motion.get("x", 0.0)) * sin(float(motion.get("x_speed", 1.0)) * time),
		float(motion.get("y", 0.0)) * sin(float(motion.get("y_speed", 1.0)) * time),
		float(motion.get("rotation", 0.0)) * sin(float(motion.get("rotation_speed", 1.0)) * time))

func sway(control: Control, kind: String) -> void:
	var offset: = drift(kind)
	pose(control, Vector2(offset.x, offset.y) * control.size, offset.z)

static func pose(control: Control, position: Vector2, rotation: float, scale: float = 1.0) -> void:
	control.offset_transform_enabled = position != Vector2.ZERO or rotation != 0.0 or scale != 1.0
	control.offset_transform_visual_only = true
	control.offset_transform_pivot_ratio = Vector2.ONE * 0.5
	control.offset_transform_position = position
	control.offset_transform_rotation = rotation
	control.offset_transform_scale = Vector2.ONE * scale

func shade(item: CanvasItem, kind: String) -> void:
	var material: ShaderMaterial = item.get_meta(&"theme_material") if item.has_meta(&"theme_material") else ShaderMaterial.new()
	item.set_meta(&"theme_material", material)
	if dress(kind, material, null) or item.material == material:
		item.material = material if material.shader else null

func dress(kind: String, material: ShaderMaterial, fallback: Shader) -> bool:
	var entry: = _dict(_dict(active, "shaders"), kind)
	var shader: = shader_of(str(entry.get("file", "")))
	material.shader = shader if shader else fallback
	var uniforms: = _dict(entry, "uniforms")
	for uniform: Variant in uniforms:
		material.set_shader_parameter(str(uniform), uniform_value(uniforms[uniform]))
	return shader != null

func texture_of(file: String) -> Texture2D:
	return _textures.get(file)

func watch(file: String, viewer: CanvasItem) -> void :
	if _players.has(file):
		_players[file].watch(viewer)

func _load_backgrounds() -> void :
	var root: = str(active.get("path", ""))
	if root != _texture_root:
		_texture_root = root
		_clear_media()
		_shaders = {}
		_samplers = {}
	layers = layers_of(active)
	overlays = overlays_of(active)
	var files: = PackedStringArray()
	for layer in layers:
		var file: = str(layer.get("file", ""))
		if str(layer["type"]) == "image" and not file.is_empty() and not files.has(file):
			files.append(file)
	for file: String in _textures.keys():
		if not files.has(file):
			_forget_media(file)
	for file in files:
		if not _textures.has(file):
			_load_media(file)
	backgrounds_changed.emit()

func _load_media(file: String) -> void :
	_textures[file] = null
	var player: = MotionPlayer.create(_texture_root.path_join(file))
	if player == null:
		_l.warn("The theme background '%s' could not be loaded" % file)
		return
	player.playing = str(SettingsManager.performance.background) != "simple"
	player.on_demand = true
	player.settled.connect(_on_media_settled.bind(file, player))
	_players[file] = player
	add_child(player)

func _on_media_settled(error: String, file: String, player: MotionPlayer) -> void :
	if _players.get(file) != player:
		return
	if not error.is_empty():
		_l.warn("The theme background '%s' could not be loaded: %s" % [file, error])
		return
	_textures[file] = player.texture
	_l.log("Theme background '%s' plays with %s" % [file, player.describe()])
	backgrounds_changed.emit()

func _forget_media(file: String) -> void :
	if _players.has(file):
		_players[file].queue_free()
		_players.erase(file)
	_textures.erase(file)

func _clear_media() -> void :
	for file: String in _textures.keys():
		_forget_media(file)

func _reload_media() -> void :
	_clear_media()
	_load_backgrounds()

func _hold_still() -> void :
	var still: = str(SettingsManager.performance.background) == "simple"
	for player: MotionPlayer in _players.values():
		player.playing = not still
