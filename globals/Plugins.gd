extends Node

signal plugins_changed
signal install_finished(error: String)
signal plugin_failed(entry: Dictionary)
signal nari_ready

const DIR: = "user://plugins"
const DATA_DIR: = "user://plugin_data"
const STAGING_DIR: = "user://plugin_staging"
const API: = 1
const SESSION_FILE: = "user://session.json"
const STABLE_AFTER: = 30.0
const CRASH_LIMIT: = 3
const SAFE_TITLE: = "SAFE MODE ENABLED"
const FLOOD_LIMIT: = 20
const FLOOD_WINDOW_MS: = 5000
const ERROR_HISTORY: = 200
const LINK_PREFIX: = "nari://plugin/"
const GLYPH: = preload("res://assets/icons/plugin.svg")
const LOCATION: = "([^\\s:'\"]+\\.lua):(\\d+):\\s*"
const TRACE_LOCATION: = "(?m)^([^\\s:]+\\.lua):(\\d+):"
const ALL_ACCESS: = "all"
const NEEDS_APPROVAL: = "it asks for All access: open it in Settings → Plugins and allow it to turn it on"

var manifests: = {}
var safe_mode: = false
var home_entries: Array[Dictionary] = []
var now_playing_tabs: Array[Dictionary] = []
var settings_extras: Array[Dictionary] = []
var effects: Array[Dictionary] = []
var item_actions: Array[Dictionary] = []
var discover_sections: Array[Dictionary] = []
var errors: Array[Dictionary] = []
var _active: = {}
var _nari_ready: = false
var _l: = Log.new("Plugins", Color("f2a65e"))
var _http: = HTTPService.new()
var _halted: = {}
var _bursts: = {}
var _location: = RegEx.create_from_string(LOCATION)
var _trace_location: = RegEx.create_from_string(TRACE_LOCATION)

func _ready() -> void :
	add_child(_http)
	_track_session()
	DirAccess.make_dir_recursive_absolute(DIR)
	scan()
	SettingsManager.changed.connect( func(section: String, key: String, _value: Variant):
		if section == "plugins" and key == "enabled":
			_sync())
	if Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").connect("plugin_picked", func(path: String):
			if not path.is_empty():
				install_finished.emit(install(path)))
		Engine.get_singleton("MusicService").connect("link_opened", MediaPlayer.open_target)
	_start.call_deferred()

func _track_session() -> void :
	var session: = JsonUtil.parse_dict(FileAccess.get_file_as_string(SESSION_FILE)) if FileAccess.file_exists(SESSION_FILE) else {}
	var crashes: = int(session.get("crashes", 0)) + 1 if session.get("running", false) else 0
	safe_mode = crashes >= CRASH_LIMIT
	if safe_mode:
		crashes = 0
		_l.warn("Nari closed unexpectedly %d times in a row, plugins stay off this session" % CRASH_LIMIT)
	_write_session(true, crashes)
	get_tree().create_timer(STABLE_AFTER).timeout.connect(_write_session.bind(false, 0))

func _write_session(running: bool, crashes: int) -> void :
	FileUtil.write_json(SESSION_FILE, {"running": running, "crashes": crashes})

func _exit_tree() -> void :
	_write_session(false, 0)

func _start() -> void :
	_nari_ready = true
	for plugin: NariPlugin in _active.values():
		plugin._on_nari_ready()
	nari_ready.emit()

func is_nari_ready() -> bool:
	return _nari_ready

func is_enabled(id: String) -> bool:
	return _active.has(id)

func is_marked(id: String) -> bool:
	return SettingsManager.plugins.enabled.has(id)

func enable_problem(id: String) -> String:
	return Package.version_problem(manifests.get(id, {}), id)

func permissions_of(id: String) -> PackedStringArray:
	return Package.permissions(manifests.get(id, {}))

func needs_all_access(id: String) -> bool:
	return ALL_ACCESS in permissions_of(id)

func is_approved(id: String) -> bool:
	return not needs_all_access(id) or SettingsManager.plugins.approved.has(id)

func approve(id: String) -> void :
	SettingsManager.plugins.set_approved(id, true)
	_halted.erase(id)

func get_plugin(id: String) -> NariPlugin:
	return _active.get(id)

func settings_entries(category: String) -> Array:
	var entries: Array = []
	for extra in settings_extras:
		if extra["category"] == category:
			var built: Variant = (extra["builder"] as Callable).call()
			if built is Array:
				entries.append_array((built as Array).filter(func(entry: Variant): return entry is Dictionary))
	return entries

func screenshot_sources(id: String) -> PackedStringArray:
	return Package.sources(manifests.get(id, {}), "screenshots")

func load_screenshot(id: String, source: String) -> Texture2D:
	if not source.begins_with("http"):
		return NariPlugin.load_file(source) as Texture2D
	var cached: = DATA_DIR.path_join(id).path_join("screenshots").path_join(source.md5_text() + ".png")
	if FileAccess.file_exists(cached):
		return NariPlugin.load_file(cached) as Texture2D
	var response: = await _http.request(source)
	var image: = response.body_as_image() if response and response.succeeded() else null
	if image == null:
		return null
	DirAccess.make_dir_recursive_absolute(cached.get_base_dir())
	image.save_png(cached)
	return ImageTexture.create_from_image(image)

func image_of(id: String) -> Texture2D:
	var manifest: Dictionary = manifests.get(id, {})
	var image: = NariPlugin.load_file(str(manifest["path"]).path_join(str(manifest["icon"]))) as Texture2D if manifest.has("icon") else null
	return image if image else Package.placeholder(GLYPH, Themes.theme_of({}))

func pick() -> void :
	if Engine.has_singleton("MusicService"):
		Engine.get_singleton("MusicService").pickPlugin()

func pick_text(extensions: PackedStringArray = PackedStringArray()) -> String:
	if not Engine.has_singleton("MusicService"):
		return ""
	var native: Object = Engine.get_singleton("MusicService")
	native.pickTextFile(extensions)
	return await native.text_picked

func install(zip_path: String) -> String:
	var root: = Package.extract(zip_path, STAGING_DIR)
	if root.is_empty():
		return "The file is not a zip archive"
	var problem: = adopt(root)
	Package.remove(STAGING_DIR)
	if problem.is_empty():
		DirAccess.remove_absolute(zip_path)
	return problem

func adopt(root: String) -> String:
	var manifest: = Package.manifest_at(root)
	var id: = str(manifest.get("id", ""))
	var problem: = Package.problem(manifest, id, API)
	if problem.is_empty():
		problem = Package.id_problem(id)
	if problem.is_empty():
		problem = Package.permissions_problem(manifest)
	if problem.is_empty():
		problem = _missing(manifest, func(file: String): return FileAccess.file_exists(root.path_join(file)))
	if not problem.is_empty():
		return "This plugin can't be installed: %s" % problem
	var target: = DIR.path_join(id)
	if _active.has(id):
		_disable(id)
	Package.remove(target)
	if DirAccess.rename_absolute(root, target) != OK:
		return "Nari could not write the plugin files"
	_l.log("Installed plugin '%s' %s" % [id, manifest.get("version", "")])
	scan()
	return ""

func uninstall(id: String) -> void :
	SettingsManager.plugins.set_enabled(id, false)
	SettingsManager.plugins.set_approved(id, false)
	Package.remove(DIR.path_join(id))
	Package.remove(DATA_DIR.path_join(id))
	for extension in ["json", "private"]:
		DirAccess.remove_absolute(DATA_DIR.path_join("%s.%s" % [id, extension]))
	_l.log("Uninstalled plugin '%s'" % id)
	scan()

func _missing(manifest: Dictionary, exists: Callable) -> String:
	if not exists.call(_main_of(manifest)):
		return "its main script is missing"
	return ""

func _main_of(manifest: Dictionary) -> String:
	return str(manifest.get("main", "main.lua"))

func scan() -> void :
	manifests.clear()
	for folder in DirAccess.get_directories_at(DIR):
		var path: = DIR.path_join(folder)
		var manifest: = JsonUtil.parse_dict(FileAccess.get_file_as_string(path.path_join("manifest.json")))
		var problem: = Package.problem(manifest, folder, API)
		if problem.is_empty():
			problem = Package.permissions_problem(manifest)
		if problem.is_empty():
			problem = _missing(manifest, func(file: String): return FileAccess.file_exists(path.path_join(file)))
		if not problem.is_empty():
			if is_marked(folder):
				report_error(folder, problem)
			else:
				_l.warn("Skipped plugin '%s': %s" % [folder, problem])
			continue
		manifest["path"] = path
		manifests[folder] = manifest
	_sync()

func _sync() -> void :
	var wanted: = SettingsManager.plugins.enabled
	for id: String in _halted.keys():
		if not wanted.has(id):
			_halted.erase(id)
	for id: String in _active.keys():
		if not wanted.has(id) or not manifests.has(id):
			_disable(id)
	for id in wanted:
		if safe_mode or not manifests.has(id) or _active.has(id) or _halted.has(id):
			continue
		var problem: = enable_problem(id)
		if problem.is_empty() and not is_approved(id):
			problem = NEEDS_APPROVAL
		if problem.is_empty():
			_enable(id)
		else:
			_halted[id] = true
			report_error(id, problem)
	plugins_changed.emit()

func reload_all() -> void :
	for id: String in _active.keys():
		_disable(id)
	_halted.clear()
	_bursts.clear()
	safe_mode = false
	scan()
	_l.log("Reloaded every plugin")

func open_link(url: String) -> bool:
	if not url.begins_with(LINK_PREFIX):
		_l.warn("Ignored the link '%s': links look like %s<plugin id>/…" % [HTTPService.redact(url), LINK_PREFIX])
		return false
	var id: = url.trim_prefix(LINK_PREFIX).get_slice("/", 0).get_slice("?", 0)
	var plugin: NariPlugin = _active.get(id)
	if plugin == null:
		_l.warn("Ignored the link '%s': the plugin '%s' isn't on" % [HTTPService.redact(url), id])
		return false
	plugin.emit_event("link", [url])
	return true

func is_halted(id: String) -> bool:
	return _halted.has(id)

func report_error(id: String, message: String, trace: String = "", fatal: bool = false) -> void :
	var now: = Time.get_ticks_msec()
	var burst: Array = _bursts.get(id, []).filter(func(at: int) -> bool: return now - at < FLOOD_WINDOW_MS)
	burst.append(now)
	_bursts[id] = burst
	if burst.size() >= FLOOD_LIMIT and _active.has(id) and not fatal:
		fatal = true
		message += " (it failed %d times in a row, so it was stopped)" % burst.size()
	var found: = _location.search(message)
	var place: = found if found else _trace_location.search(trace)
	var entry: = {
		"id": id,
		"name": Themes.script_name(id) if Themes.is_theme_script(id) else str(manifests.get(id, {}).get("name", id)),
		"message": message.substr(0, found.get_start()) + message.substr(found.get_end()) if found else message,
		"file": place.get_string(1) if place else "",
		"line": int(place.get_string(2)) if place else 0,
		"trace": trace,
		"fatal": fatal,
		"time": Time.get_time_string_from_system(),
	}
	errors.append(entry)
	if errors.size() > ERROR_HISTORY:
		errors.pop_front()
	var what: = "The script of theme '%s'" % entry["name"] if Themes.is_theme_script(id) else "Plugin '%s'" % id
	_l.error("%s failed: %s%s" % [what, message, "\n" + trace if not trace.is_empty() else ""])
	if fatal and _active.has(id):
		_halted[id] = true
		_bursts.erase(id)
		_disable(id)
		plugins_changed.emit()
	plugin_failed.emit(entry)

func _enable(id: String) -> void :
	var manifest: Dictionary = manifests[id]
	var plugin: = NariPlugin.new()
	plugin.id = id
	plugin.name = id
	plugin.manifest = manifest
	add_child(plugin)
	var problem: = plugin.start(_main_of(manifest))
	if not problem.is_empty():
		_halted[id] = true
		plugin.teardown()
		plugin.queue_free()
		return
	_active[id] = plugin
	if _nari_ready:
		plugin._on_nari_ready()
	_l.log("Enabled plugin '%s' %s" % [id, manifest.get("version", "")])

func _disable(id: String) -> void :
	var plugin: NariPlugin = _active[id]
	_active.erase(id)
	plugin.teardown()
	plugin.queue_free()
	_l.log("Disabled plugin '%s'" % id)
