extends Node

signal index_changed
signal install_finished(id: String, error: String)

const INDEX: = "https://cdn.narimusic.com/index.json"
const MIRRORS: = ["https://nari-website.pages.dev/", "https://narimusic.com/"]
const FILES: = "api/files/"
const CDN_TIMEOUT: = 6.0
const RECORD_FILE: = "user://marketplace.json"
const CACHE_DIR: = "user://marketplace_cache"
const STALE_AFTER_MS: = 600000
const AUTO_UPDATE_DELAY: = 20.0
const KINDS: = {"plugins": "zip", "themes": "naritheme"}

var manifests: = {}
var loading: = false
var failed: = false
var _index_url: = INDEX
var _base: = ""
var _custom: = false
var _mirror: = ""
var _fetched_at: = -STALE_AFTER_MS
var _icons: = {}
var _installing: = {}
var _http: = HTTPService.new()
var _l: = Log.new("Marketplace", Color("5ec2f2"))

func _ready() -> void :
	add_child(_http)
	var custom: = OS.get_environment("NARI_MARKETPLACE")
	if not custom.is_empty():
		_index_url = custom
		_custom = true
	_base = _index_url.get_base_dir() + "/"
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	SettingsManager.changed.connect( func(section: String, key: String, value: Variant):
		if section == "plugins" and key == "auto_update" and value:
			update_all())
	if SettingsManager.plugins.auto_update:
		get_tree().create_timer(AUTO_UPDATE_DELAY).timeout.connect(update_all)

func refresh(force: = false) -> void :
	if loading or (not force and not manifests.is_empty() and Time.get_ticks_msec() - _fetched_at < STALE_AFTER_MS):
		return
	loading = true
	failed = false
	index_changed.emit()
	var response: = await _fetch_index()
	loading = false
	if response and response.code == 404:
		manifests = {}
	elif response == null or not response.succeeded():
		failed = true
		index_changed.emit()
		return
	else:
		manifests = _read(response.body_as_dict())
	_fetched_at = Time.get_ticks_msec()
	index_changed.emit()

func _fetch_index() -> HTTPService.HTTPResponse:
	if _custom:
		return await _http.request(_index_url, PackedStringArray(), HTTPClient.METHOD_GET, "", 0, HTTPService.TIMEOUT)
	var order: = MIRRORS.duplicate()
	order.sort_custom(func(mirror: String, _other: String): return mirror == _mirror)
	for mirror: String in order:
		var mirrored: = await _http.request(mirror + FILES + "index.json", PackedStringArray(), HTTPClient.METHOD_GET, "", 0, CDN_TIMEOUT)
		if mirrored and (mirrored.succeeded() or mirrored.code == 404):
			_mirror = mirror
			_base = mirror + FILES
			return mirrored
		_l.warn("The marketplace didn't answer at %s" % mirror)
	_mirror = ""
	_base = INDEX.get_base_dir() + "/"
	return await _http.request(INDEX, PackedStringArray(), HTTPClient.METHOD_GET, "", 0, CDN_TIMEOUT)

func _read(index: Dictionary) -> Dictionary:
	var found: = {}
	for kind: String in KINDS:
		var listed: Variant = index.get(kind, [])
		for entry: Variant in listed if listed is Array else []:
			if not entry is Dictionary or str(entry.get("id", "")).is_empty():
				continue
			var manifest: Dictionary = (entry as Dictionary).duplicate(true)
			var api: = int(manifest.get("api", 0))
			if api < 1 or api > (Themes.API if kind == "themes" else Plugins.API) or not Package.version_problem(manifest, str(manifest["id"])).is_empty():
				continue
			manifest["kind"] = kind
			manifest["store"] = {"source": manifest.get("source", ""), "license": manifest.get("license", ""), "updated": manifest.get("updated", "")}
			found[str(manifest["id"])] = manifest
	return found

func entries(kind: String) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for manifest: Dictionary in manifests.values():
		if manifest["kind"] == kind:
			found.append(manifest)
	found.sort_custom( func(first: Dictionary, second: Dictionary):
		if bool(first.get("featured", false)) != bool(second.get("featured", false)):
			return bool(first.get("featured", false))
		return str(first.get("name", "")).naturalnocasecmp_to(str(second.get("name", ""))) < 0)
	return found

func url(path: String) -> String:
	return path if path.begins_with("https://") or path.begins_with("http://") else _base + path

func _download_url(manifest: Dictionary) -> String:
	var link: = url(str(manifest.get("download", "")))
	if _mirror.is_empty() or not link.contains("/api/download/"):
		return link
	return _mirror + link.substr(link.find("api/download/")) + "?via=api"

func downloads_text(count: int) -> String:
	if count >= 1000:
		return "%.1fk downloads" % (count / 1000.0)
	return "1 download" if count == 1 else "%d downloads" % count

func installed_source(id: String) -> Node:
	if Themes.manifests.has(id):
		return Themes
	if Plugins.manifests.has(id):
		return Plugins
	return null

func is_installed(id: String) -> bool:
	return installed_source(id) != null

func is_installing(id: String) -> bool:
	return _installing.has(id)

func has_update(id: String) -> bool:
	var source: = installed_source(id)
	if not manifests.has(id) or source == null:
		return false
	return Package.older(str(source.manifests[id].get("version", "0")), str(manifests[id].get("version", "0")))

func image_of(id: String) -> Texture2D:
	if _icons.has(id):
		return _icons[id]
	var manifest: Dictionary = manifests.get(id, {})
	var glyph: DPITexture = Themes.GLYPH if manifest.get("kind") == "themes" else Plugins.GLYPH
	var icon: = ImageTexture.create_from_image(Package.placeholder(glyph, Themes.theme_of(manifest)).get_image())
	_icons[id] = icon
	if not str(manifest.get("icon", "")).is_empty():
		_fill_icon(icon, url(str(manifest["icon"])))
	return icon

func _fill_icon(icon: ImageTexture, source: String) -> void :
	var image: = await _image(source)
	if image:
		icon.set_image(image)

func screenshot_sources(id: String) -> PackedStringArray:
	var listed: Variant = manifests.get(id, {}).get("screenshots", [])
	return PackedStringArray((listed as Array).map(func(shot: Variant): return url(str(shot)))) if listed is Array else PackedStringArray()

func load_screenshot(_id: String, source: String) -> Texture2D:
	var image: = await _image(source)
	return ImageTexture.create_from_image(image) if image else null

func _image(source: String) -> Image:
	var cached: = CACHE_DIR.path_join(source.md5_text() + ".png")
	if FileAccess.file_exists(cached):
		return Image.load_from_file(cached)
	var response: = await _http.request(source)
	var image: = _decode(response.body) if response and response.succeeded() else null
	if image:
		image.save_png(cached)
	return image

static func _decode(bytes: PackedByteArray) -> Image:
	var image: = Image.new()
	var header: = bytes.slice(0, 12)
	var loaded: = ERR_FILE_UNRECOGNIZED
	if header.slice(0, 4) == PackedByteArray([0x89, 0x50, 0x4e, 0x47]):
		loaded = image.load_png_from_buffer(bytes)
	elif header.slice(0, 2) == PackedByteArray([0xff, 0xd8]):
		loaded = image.load_jpg_from_buffer(bytes)
	elif header.slice(8, 12).get_string_from_ascii() == "WEBP":
		loaded = image.load_webp_from_buffer(bytes)
	return image if loaded == OK else null

func readme(id: String) -> String:
	var path: = str(manifests.get(id, {}).get("readme", ""))
	if path.is_empty():
		return ""
	var response: = await _http.request(url(path))
	return response.body_as_string() if response and response.succeeded() else ""

func install(id: String) -> String:
	if _installing.has(id):
		return "It's already being installed"
	var manifest: Dictionary = manifests.get(id, {})
	if manifest.is_empty():
		return "It isn't in the marketplace anymore"
	_installing[id] = true
	index_changed.emit()
	var kind: String = manifest["kind"]
	var path: = CACHE_DIR.path_join("%s.%s" % [id, KINDS[kind]])
	var problem: = ""
	if not await _http.download(_download_url(manifest), path):
		problem = "The download didn't finish, check your connection and try again"
	elif FileAccess.get_sha256(path) != str(manifest.get("sha256", "")):
		problem = "The download isn't the file that was reviewed, so it wasn't installed"
	else:
		problem = (Themes if kind == "themes" else Plugins).install(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(path)
	_installing.erase(id)
	if problem.is_empty():
		var installed: = _installed()
		installed[id] = str(manifest.get("version", ""))
		_save(installed)
		_l.log("Installed '%s' %s from the marketplace" % [id, manifest.get("version", "")])
	else:
		_l.warn("Couldn't install '%s' from the marketplace: %s" % [id, problem])
	index_changed.emit()
	install_finished.emit(id, problem)
	return problem

func update_all() -> void :
	await refresh(true)
	for id: String in _installed():
		if has_update(id):
			await install(id)

func _installed() -> Dictionary:
	return JsonUtil.parse_dict(FileAccess.get_file_as_string(RECORD_FILE)) if FileAccess.file_exists(RECORD_FILE) else {}

func _save(installed: Dictionary) -> void :
	FileUtil.write_json(RECORD_FILE, installed)
