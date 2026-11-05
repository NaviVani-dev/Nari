extends Node

signal skins_changed

const API := 1
const FORMATS := {"winamp": "wsz", "wmp": "wmz", "nari": "nsk"}
const KIND_FORMATS := {"Winamp": "winamp", "Windows Media Player": "wmp", "Nari": "nari"}
const INFO := "user://cache/skin_info"
const GLYPH := preload("res://assets/icons/mini_player.svg")
const DECLARED := "skin_settings"

var manifests := {}
var _ids := {}

func _ready() -> void:
	if OS.has_feature("pc"):
		scan()

func scan() -> void:
	manifests = {}
	_ids = {}
	for file in WinampSkin.choices().slice(1):
		var manifest := _read(file)
		manifests[manifest["id"]] = manifest
		_ids[file] = manifest["id"]
	skins_changed.emit()

func _read(file: String) -> Dictionary:
	var info := INFO.path_join(file.md5_text())
	var folder := DirAccess.dir_exists_absolute(file)
	if folder or not DirAccess.dir_exists_absolute(info):
		_unpack(file, info)
	var manifest := Package.manifest_at(info)
	manifest.merge({"id": file.get_file().get_basename(), "name": WinampSkin.label(file), "description": WinampSkin.kind(file) + " skin", "skin": KIND_FORMATS[WinampSkin.kind(file)]})
	manifest.merge({"path": info, "file": file, "size": PluginInfo._weight(file) if folder else FileAccess.get_size(file)}, true)
	return manifest

func _unpack(file: String, info: String) -> void:
	var zip := ZIPReader.new()
	var zipped := not DirAccess.dir_exists_absolute(file) and zip.open(WinampSkin.local(file)) == OK
	var listed := zip.get_files() if zipped else PackedStringArray()
	var root: String = "" if not zipped or listed.has("manifest.json") else Array(listed).reduce(func(found: String, name: String): return name.get_base_dir() + "/" if found.is_empty() and name.count("/") == 1 and name.ends_with("/manifest.json") else found, "")
	var read := func(name: String) -> PackedByteArray: return (zip.read_file(root + name) if listed.has(root + name) else PackedByteArray()) if zipped else FileAccess.get_file_as_bytes(file.path_join(name))
	var raw: PackedByteArray = read.call("manifest.json")
	var manifest := JsonUtil.parse_dict(raw.get_string_from_utf8() if raw else "{}")
	DirAccess.make_dir_recursive_absolute(info)
	FileUtil.write_json(info.path_join("manifest.json"), manifest)
	for name: String in ["README.md", str(manifest.get("icon", ""))] + (manifest["screenshots"] if manifest.get("screenshots") is Array else []).map(str):
		var bytes: PackedByteArray = read.call(name) if not name.is_empty() and not ".." in name else PackedByteArray()
		if not bytes.is_empty():
			DirAccess.make_dir_recursive_absolute(info.path_join(name).get_base_dir())
			FileAccess.open(info.path_join(name), FileAccess.WRITE).store_buffer(bytes)
	if zipped:
		zip.close()
	if not manifest.has("icon") and WinampSkin.kind(file) == "Winamp":
		_preview(file, info)

func _preview(file: String, info: String) -> void:
	var skin := WinampSkin.open(file)
	var main: Image = skin.images["main"].duplicate() if skin and skin.images.has("main") else null
	if not main:
		return
	if skin.images.has("titlebar"):
		main.blit_rect(skin.images["titlebar"], Rect2i(27, 0, 275, 14), Vector2i.ZERO)
	main.resize(main.get_width() * 4, main.get_height() * 4, Image.INTERPOLATE_NEAREST)
	main.save_png(info.path_join("preview.png"))
	var manifest := Package.manifest_at(info)
	manifest.merge({"icon": "preview.png", "screenshots": ["preview.png"]})
	FileUtil.write_json(info.path_join("manifest.json"), manifest)

func forget(file: String) -> void:
	Package.remove(INFO.path_join(file.md5_text()))
	scan()

func manifest_of(file: String) -> Dictionary:
	return manifests.get(_ids.get(file, ""), {})

func is_builtin(id: String) -> bool:
	return str(manifests.get(id, {}).get("file", "")).begins_with(WinampSkin.BUNDLED)

func is_active(id: String) -> bool:
	return manifests.has(id) and WinampSkin.current() == manifests[id]["file"]

func use(id: String) -> void:
	SettingsManager.set_value(WinampPlayer.SECTION, "skin", "" if is_active(id) else str(manifests.get(id, {}).get("file", "")))

static func settings_section(id: String) -> String:
	return "skin:" + id

func settings_for(id: String) -> Array[Dictionary]:
	var found := Themes.settings_of(manifests.get(id, {}))
	var taken := found.map(func(setting: Dictionary): return str(setting["id"]))
	found.append_array(Themes.settings_of({"settings": SettingsManager.get_value(DECLARED, id, [])}).filter(func(setting: Dictionary): return not str(setting["id"]) in taken))
	return found

func script_settings(id: String, listed: Array) -> void:
	SettingsManager.set_value(DECLARED, id, listed)

func setting_value(id: String, key: String) -> Variant:
	for setting in settings_for(id):
		if str(setting["id"]) == key:
			return SettingsManager.get_value(settings_section(id), key, setting.get("default"))
	return null

func setting_label(id: String, setting: Dictionary) -> String:
	return Themes.label_of(setting, setting_value(id, str(setting["id"])))

func next_setting_value(id: String, setting: Dictionary) -> Variant:
	return Themes.next_of(setting, setting_value(id, str(setting["id"])))

func install(path: String) -> String:
	return "" if not WinampSkin.install(path).is_empty() else "Nari could not write the skin files"

func uninstall(id: String) -> void:
	if manifests.has(id) and not is_builtin(id):
		WinampSkin.remove(manifests[id]["file"])

func image_of(id: String) -> Texture2D:
	var manifest: Dictionary = manifests.get(id, {})
	var image := NariPlugin.load_file(str(manifest["path"]).path_join(str(manifest["icon"]))) as Texture2D if manifest.has("icon") else null
	return image if image else Package.placeholder(GLYPH, Themes.theme_of({}))

func screenshot_sources(id: String) -> PackedStringArray:
	return Package.sources(manifests.get(id, {}), "screenshots")

func load_screenshot(id: String, source: String) -> Texture2D:
	return await Plugins.load_screenshot(id, source)
